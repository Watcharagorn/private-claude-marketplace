# Surface catalog

The primitives and families the scenario stage draws from. `surface-mockup-contract.md` owns every rule the
primitives share (hops, markup, ids, CSS isolation, host chrome, images, markers, provenance, Before/After,
Self-check); this file says only what differs per primitive and per family.

- **Whoever traces in §1** (the trace worker, or the main thread when it traces itself): the §2 family table
  and the shape fallback, to resolve each hop's primitive.
- **Each cells worker:** the §1 sections for its own primitives, and §3.

Facts marked "(verify)" are vendor limits or UI behaviour that change between releases. Re-check them
against the vendor's docs before a mockup relies on them.

**Reading the "Edge cards and variants" rows.** Each primitive lists what a card of that surface can
change. Whether a change is an edge card, a variant or a frame of its hop is decided by
`surface-mockup-contract.md` "3. Edge cards and variants".

**Nesting.** A side output in the same host nests in the frame of the step that produced it and never starts
a hop: a toast inside a P1 frame, a rich card (P4) or tool call (P7) inside a P3 thread, a Change-set (P11)
inside a P2 session or a P3 thread. A P6 notification whose tap opens a screen leads to the next hop.

## 1. Rendering primitives (11)

### P1 Screen frame

| Aspect | Spec |
|---|---|
| Used by | Web, mobile, desktop, browser extension, IDE extension |
| Chrome | One of four variants. Browser: an address pill showing the real route path, no browser brand. Phone: a status strip and safe-area insets. Desktop window: the app's real window title and the menu row from its real menu template. Host-embedded: a grey schematic host (editor with a sidebar, or browser toolbar with a popup anchored to it) with the project's contributed panel exact |
| Edge cards and variants | Edge cards swap the viewport content for an outcome off the main path: empty, error, forbidden, offline. Variants keep the outcome: long text, dark mode, a platform. The 360 px width is the card's width axis (`surface-mockup-contract.md` §8), not a variant. Loading is a frame of its hop. The chrome changes only when a frame navigates (route, title) |
| Before/After | Same viewport and data. The content swaps, and After carries markers |
| HTML/CSS | The viewport is a `.pv-payload` subtree of real DOM, styled by project tokens and the pinned framework build. If the layout uses **viewport media queries** (Tailwind `sm:`, `md:` and so on), a 360 px `div` will **not** reflow. Render that frame once as an `<iframe srcdoc>` with the same pinned CDN inside, and let the width toggle resize the same iframe (default or 360 px) instead of authoring a second copy. Each frame then ships one source, which keeps the page under the 1 MB warning. Escape `srcdoc` with `&` first, then `"`, then `<` as `&lt;` (the contract's §5), so the pinned script inside never appears as a literal tag in the hop file |
| Narrow and markers | 360 px is real reflow (via the iframe when needed). Markers sit on the element in both widths |
| Accessibility | Content stays real text. A control that advances the flow is a link to the next hop's anchor, or a `<label for>` the next variant's radio (`page-contract.md` §4), never a script; frames inside one hop have no radio of their own. Inert controls get `aria-disabled="true"`. The mockup's own contrast failures in Before are shown and flagged, not silently fixed |

### P2 Terminal session

| Aspect | Spec |
|---|---|
| Used by | CLI output, interactive TUI or prompt, REPL, IDE output channel, host for Change-set |
| Chrome | A grey bar labelled "Terminal (schematic)". A prompt line `$ <real command and flags>`. The output body. A footer badge `exit <n>`. stderr lines carry a left rule and a `stderr` tag. A mode badge reads `TTY` or `piped`, because colour and spinners differ between them |
| Edge cards and variants | A different stream or exit code is an edge card (a usage error, auth missing). The same stream and exit code with different text stays in one card, with a Differences list. TTY against piped is a variant. TUI steps are frames at keystroke points, captioned with the keys that led there (`↓ ↓ Enter`) |
| Before/After | Same command, old code against new code. Changed lines get a gutter marker, and lines removed in Before are marked too. A TUI follows the same keystroke path on both sides |
| HTML/CSS | `<pre>` with `white-space: pre`, a monospace stack, and width in `ch` (80, or the tool's declared width). ANSI colours map to scoped custom properties, and only the colours the code actually emits get one. Box-drawing characters draw TUI borders |
| Narrow and markers | **Never wrap.** Wrapping fakes the column layout. The frame scrolls horizontally, with a column ruler. If the tool reads the terminal width, "narrow" is a separate variant, not a CSS reflow. Markers sit in the left gutter |
| Accessibility | Caption: "Terminal: `<command>`, exit 2". The `pre` is focusable (`tabindex="0"`) so it can scroll from the keyboard. The stream tag and the tool's own ✓/✗ glyphs mean colour is never the only signal. The ANSI palette is checked for AA on the frame background in both themes |

### P3 Conversation thread

| Aspect | Spec |
|---|---|
| Used by | Chat platforms (as host of Rich card), SMS, AI assistant, in-product chatbot |
| Chrome | A schematic channel header (the channel or DM name from config). Rows carry an initials avatar, the real sender display name, a bot or app tag, and a timestamp marked illustrative. Three layouts: channel (all left), bubbles (SMS: left and right), assistant (user turn, assistant turn, and full-width tool blocks) |
| Edge cards and variants | Which messages exist (ephemeral "only visible to you", edited, thread reply, error reply), their content, and the nested card or tool block. An error reply is an edge card; an edit or a thread placement is a variant |
| Before/After | Old message or card against new, in the same thread. When the bot or channel already exists, an absence in Before is meaningful |
| HTML/CSS | `<ol class="pv-thread">` of `<li><article>`. Tool blocks are `<details>` holding a P7 Wire exchange. SMS adds a segment badge (encoding and count) |
| Narrow and markers | Single column already. Nested cards go to 100% width, with `overflow-wrap: anywhere` for long tokens. Markers go on the changed message or block |
| Accessibility | Bubbles differ by position **and** by a visible sender name. Fill colours meet AA. No streaming effect |

### P4 Rich card

| Aspect | Spec |
|---|---|
| Used by | Slack Block Kit, Google Chat cardsV2, Teams Adaptive Card, Discord embeds and components, LINE Flex, link unfurls |
| Chrome | A card box inside a P3 thread, or standalone. Elements are stacked in payload order. Buttons keep their real labels, and their style hints (primary, danger) show as neutral emphasis, never vendor colour. A strip reads "Notification text: …", using Slack `text`, LINE `altText` or the equivalent. Below the card is a collapsed `<details>` **Payload** view. P4 standalone also covers a modal or Home view, whose `title`, `submit` and `close` labels come from the `view` payload |
| Edge cards and variants | The payload (fields, buttons, status), and interaction outcomes: updated in place, replaced, ephemeral reply, interaction failed (the platform's own error text, verify), and disabled or expired buttons. A failed or expired interaction is an edge card |
| Before/After | Old payload against new payload. The Payload view marks added and removed keys |
| HTML/CSS | Hand-authored. **One DOM block per payload element**, each with `data-el="<element type>"`. An element the platform doesn't support is drawn as a dashed box labelled with its type. Hero and header images use the image placeholder. The exact JSON goes in a `<pre>`, with secrets redacted and keys kept |
| Narrow and markers | Columns stack only where the platform stacks them (verify per platform). A carousel scrolls horizontally. Markers go per element |
| Accessibility | The card is an `<article>` whose heading is the card title. Status is in text (from the payload), not colour alone |

### P5 Mail message

| Aspect | Spec |
|---|---|
| Used by | Transactional, alert, digest and invite email |
| Chrome | Three stacked `<details>` views, all schematic. **Inbox row:** sender, subject, preheader. **Open:** an envelope grid (From name and address, Reply-To, To, Subject, Date, and `List-Unsubscribe` / `List-Unsubscribe-Post` when the code sets them), then the body. **Plain text:** the text/plain alternative, verbatim |
| Edge cards and variants | A missing variable and an unsubscribed recipient (not sent) are edge cards. Very long values, images blocked and dark mode (labelled approximate) are variants (`long`, `images-blocked`, `dark`), and so are footer variants |
| Before/After | Old template against new, with the same sample data |
| HTML/CSS | The body is the **real template** filled with fixture values, inside `<iframe sandbox srcdoc>` (no `allow-scripts`, like real mail clients) at the template's own width. Escape `&` first, then `"`. Remote images use the alt placeholder, which is exactly the images-blocked rendering. A long template may become an excerpt, made as `surface-mockup-contract.md` §8 → **Whole screens from the real components** says |
| Narrow and markers | The iframe is set to 360 px, so the template's own media queries fire. Markers sit on the envelope fields, plus a callout list for body changes |
| Accessibility | The iframe has `title="Email body: <template>"`. Each view is a `<details>` whose `<summary>` names it. The preheader is real text |

### P6 Notification

| Aspect | Spec |
|---|---|
| Used by | Mobile and web push, OS desktop notifications, in-app toast, snackbar and banner, the SMS lock-screen preview, editor toasts |
| Chrome | Lock-screen stack, top banner, desktop toast, or an in-app toast inside a P1 frame. OS variants are grey schematics. App identity is an initials tile plus the real display name (from the manifest, `Info.plist`, `strings.xml` or `productName`). The time "now" is illustrative. Action buttons carry their real labels. In-app toasts use the project's toast-library tokens, because that UI is project-controlled |
| Edge cards and variants | Edge cards: app in the foreground (no banner), permission denied (render "Not shown: permission denied"). Variants: collapsed or expanded, grouped, long body truncated, platform. An action tap leads to the next hop |
| Before/After | Old copy, trigger and type against new, in the same frame |
| HTML/CSS | Scoped `div`s, with `-webkit-line-clamp` set to the line counts in the limits table (verify). No slide-in animation |
| Narrow and markers | The lock-screen frame is about 360 px wide already. A desktop toast keeps its fixed width. Markers go on the title, body or action |
| Accessibility | Static readable text, not a live region. "Rules and edges" notes the role the real toast uses (`status` or `alert`) when the code sets one |

### P7 Wire exchange (`call` and `delivery` modes)

| Aspect | Spec |
|---|---|
| Used by | REST, gRPC and grpc-gateway, GraphQL, JSON-RPC (including MCP tool calls), webhooks, queue messages, CloudEvents |
| Chrome | **call:** a request pane (method and path, or `pkg.Service/Method`, the relevant headers and metadata with credentials redacted, the body) and a response pane (a status pill reading HTTP code and reason, or gRPC name and number, the body, relevant headers such as `Retry-After`). **delivery:** an envelope table (CloudEvents attributes, or broker exchange, routing key, subject and headers), the data body, and an attempt timeline (attempt, result, next retry from the configured policy, then the DLQ). A signature or MAC header shows its name, algorithm and signed-string recipe verbatim, with its value redacted |
| Edge cards and variants | Edge cards: a different caller (role or permission), input or status, with its error body. For delivery: consumer failure, retries exhausted, DLQ, duplicate, out of order |
| Before/After | Old contract against new for the same call. Added fields get a marker, removed fields are struck through, renamed fields are marked, and status changes are marked. A new endpoint's Before reads "not there before" |
| HTML/CSS | Two `<section>`s in a CSS grid. JSON goes in a `<pre>`, coloured with key, string and number spans using scoped tokens. The status pill is both coloured and worded |
| Narrow and markers | The panes stack (request above response). Each `pre` scrolls horizontally. Markers go per field |
| Accessibility | Each pane has a "Request" or "Response" heading. Redactions are `••••` with sr-text "redacted". Each `pre` is focusable |

### P8 Spoken dialog

| Aspect | Spec |
|---|---|
| Used by | IVR, voice bots, voice-assistant skills, phone call flows |
| Chrome | A turn list labelled Caller and System. A header shows the entry number or skill name, plus the language and voice name from config. System turns show the prompt text verbatim, with SSML rendered as chips (`⟨pause 500 ms⟩`). Caller turns show a labelled sample utterance or DTMF keycaps. Separators mark `no-input 5 s`, `no-match`, `barge-in`, `transfer → <queue>` and `hang-up`. The note "Audio not reproduced" is always shown |
| Edge cards and variants | Each branch off the happy path is an edge card: no-input reprompt, no-match, max retries leading to transfer or disconnect, after-hours, auth failure |
| Before/After | Old prompts and branches against new, on the same path. Markers go on changed turns |
| HTML/CSS | An `<ol>` of turns, with chips and keycaps as inline spans. No audio playback |
| Narrow and markers | Single column already. Markers sit per turn |
| Accessibility | Text-first already. Chips carry sr-text ("pause, 500 milliseconds"), and keycaps read "presses 1" |

### P9 Document page

| Aspect | Spec |
|---|---|
| Used by | PDF reports, invoices, certificates, DOCX, CSV and XLSX exports. A label printer or other device output is not the `document` family: it is `new:<slug>` with a SURFACE BRIEF (Unknown surface, §2), drawn with P9 |
| Chrome | Paged sheets at the template's paper size and margins, with a running header and footer and "1 / N" page numbers. For tables, a spreadsheet grid whose header row comes from the code's column list. A collapsed **Raw** `<details>` shows the first N lines exactly as written: delimiter, quoting, line ending, and a BOM or encoding badge. A file-name badge follows the code's naming pattern |
| Edge cards and variants | Edge cards: empty dataset (headers only), too large (async link). Variants: one row, many rows (page 2 repeats the header), very long cell, font fallback for Thai or CJK, formula-injection escaping |
| Before/After | Old template or column set against new, with the same sample rows. Added columns are marked |
| HTML/CSS | Sheets use `aspect-ratio` and proportional padding. Tables are real `<table>`s. Raw goes in a `<pre>`. Many pages show as a strip of the first and last page. A long template may become an excerpt, made as `surface-mockup-contract.md` §8 → **Whole screens from the real components** says |
| Narrow and markers | **PDFs don't reflow**, so at 360 px the sheet scales down. Grids scroll horizontally. Markers go on the changed column, field or region |
| Accessibility | Real text with `<th scope="col">`. "Rules and edges" says whether the real PDF is tagged (from the generator config) |

### P10 Data tile

| Aspect | Spec |
|---|---|
| Used by | Ops dashboards, in-app analytics, KPI tiles, report charts, alert panels |
| Chrome | The real panel title, unit, time-range label, legend series names, and threshold lines at their real values. An **"Illustrative values"** badge, unless the data comes from fixtures |
| Edge cards and variants | Edge cards: no data, query error (the real error text). Variants: gap, threshold breached (the configured colour), too many series, loading |
| Before/After | **The same dataset on both sides.** Only the config changes (query, unit, thresholds, type), so the visual difference comes from the change alone |
| HTML/CSS | Inline SVG with precomputed paths. No chart library from a CDN: for mockups the CDN allowance covers only the project's CSS framework and icon set (Mermaid is a diagram-section fallback, never a mockup renderer) |
| Narrow and markers | `viewBox` scaling. The legend wraps below and stat tiles stack. Markers go on the changed threshold, unit or series |
| Accessibility | `role="img"` with a prefixed `<title>` and `<desc>` describing what is plotted, never a conclusion. A `<details>` data table. Series differ by dash pattern or a direct label, not colour alone. Lines and glyphs meet 3:1 |

### P11 Change-set

| Aspect | Spec |
|---|---|
| Used by | terraform, terragrunt and pulumi plans, CloudFormation change sets, kubectl, helm and argocd diffs, migration previews, RBAC-grant and config diffs |
| Chrome | One group per resource. A header shows **the tool's own action symbol** and the address. Terraform's full set is `+` create, `~` update in place, `-` destroy, `-/+` destroy then create, `+/-` create before destroy, and `<=` data source read. `kubectl diff` and helm-diff print unified diffs instead, so render those as they are. Attribute lines read `old → new`. The summary line uses the tool's own wording. A provenance badge reads **"Captured output: `<file>`"** or **"Expected, not run"** |
| Edge cards and variants | Edge cards: apply error (only if captured), a destroy the plan does not expect. Drift, replacement, no-op and a targeted subset print different lines for the same run: one card, with a Differences list |
| Before/After | The diff already is the before and after, so its cells carry `view=diff` and show the same diff in both views of the scenario's toggle. When the plan changes the tool that prints the diff, the old and new output render in P2 instead |
| HTML/CSS | One `<details open>` per resource holding a `<pre>`. Symbols sit in a fixed gutter. Sensitive values read as the tool prints them |
| Narrow and markers | Horizontal scroll per block. Markers go per resource or attribute |
| Accessibility | Symbols carry sr-text ("will be replaced"). Destroy and replace also get a text badge. The figcaption repeats the summary first, while the output keeps the tool's own order |

## 2. Surface family catalog

Twenty families, each with a slug that `_ids.md` records as `family:` (`web mobile desktop browser-extension
ide-extension cli tui chat assistant email push sms toast api event voice document dashboard infra
code-host`). A surface no row matches is `family: new:<slug>`, resolved by the shape fallback below and
recorded with a SURFACE BRIEF (`surface-mockup-contract.md`). The Primitive column is a default: the payload
the code emits decides (a Google Chat post with no `cardsV2` is P3, not P4).

| Family | Examples | Primitive | Detection signals | Fidelity source | Typical edge cards and variants | Before/After meaning |
|---|---|---|---|---|---|---|
| Web page or app (`web`) | Pages, admin consoles, forms, modals, tables | P1 browser + P6 toast | "page", "screen", "modal", "form"; `app/`, `pages/`, `src/routes/`, `components/`, `*.tsx`, `*.vue`, `*.svelte`; next, react, vue, svelte, angular; `tailwind.config.*`, CSS custom properties | Route and component files, design tokens, i18n messages, design-system doc, Storybook stories, visual or e2e snapshots | Loading, empty, error, forbidden (RBAC), validation, long text, 360 px, dark mode | Same route and data, old against new rendering |
| Mobile app (`mobile`) | iOS, Android, React Native, Flutter screens, sheets, permission prompts | P1 phone + P6 | "tap", "screen", "sheet", "deep link"; `ios/`, `android/`, `*.swift`, `*.kt`, `lib/*.dart`; react-native, expo, `pubspec.yaml`, SwiftUI, Compose | Screen source, `res/values/{colors,strings,themes}.xml`, `Assets.xcassets` colour sets, `Localizable.strings`, Flutter `ThemeData`, `app.json` | Offline, OS permission denied, first run, large dynamic type, keyboard over input, small device, RTL, dark mode | Same screen, old build against new |
| Desktop app (`desktop`) | Electron, Tauri, Qt, WPF, macOS windows, menus, tray, dialogs | P1 window | "window", "menu", "tray", "installer"; electron, `@tauri-apps/*`, `tauri.conf.json`, `*.xaml`, `*.ui`, `Info.plist` | Renderer source, the menu template, window-size config, dialog strings, `productName` | First launch, update available, offline, file missing, macOS privacy prompt, small window | Old window content against new. Native dialogs stay schematic |
| Browser extension (`browser-extension`) | Toolbar popup, options page, content-script overlay, badge, context menu | P1 host-embedded | "extension", "popup", "content script"; `manifest.json` with `manifest_version: 3`, `action`, `content_scripts`; `_locales/`; wxt, plasmo, webextension-polyfill | `manifest.json` (permissions, matches, `default_title`, popup path), popup HTML and CSS, `_locales/*/messages.json`, badge-text calls | Optional permission not granted, page not matched, logged out, service worker restarted, host page CSS clash, badge overflow | Old popup or overlay against new. The host site stays schematic on both sides |
| IDE or editor extension (`ide-extension`) | VS Code commands, views, webviews, code lenses, diagnostics; JetBrains tool windows; Neovim | P1 host-embedded + P6 + P2 (output channel) | "command palette", "code lens", "diagnostic"; `package.json` with `engines.vscode` and `contributes`; `plugin.xml`; Neovim `lua/` | `contributes` (command titles, menus, views, configuration keys and defaults, keybindings), `package.nls*.json`, strings passed to `show*Message` | No folder open, untrusted workspace (restricted mode), activation failure, invalid setting, remote host, long progress | Old contributed UI against new. The editor chrome stays schematic |
| CLI command output (`cli`) | Subcommands, help, `--json`, errors, progress | P2 (+ P11 when it prints a diff) | "command", "flag", "exit code", "`<tool> <sub>`"; `cmd/`, `bin/`, `cli/`; cobra, urfave/cli, kong, clap, click, typer, argparse, commander, yargs, oclif; `bin` in package.json, `[project.scripts]` | Golden or snapshot files first, then flag definitions and help strings, print and format calls, error strings, exit-code constants, `--json` structs | Usage error (often exit 2, check the code), auth missing or expired, network failure, non-TTY, `--json`, confirmation declined, partial failure, `NO_COLOR` | Same invocation, old binary against new |
| Interactive TUI or prompt (`tui`) | Wizards, select lists, full-screen TUIs, REPLs | P2 (one frame per keystroke) | "wizard", "interactive", "prompt", "select"; bubbletea, huh, survey, ink, `@inquirer/prompts`, `@clack/prompts`, textual, rich, ratatui, prompt_toolkit | View code (bubbletea `View()`, ink components), prompt definitions (messages, choices, defaults, validators), keymaps, teatest golden frames | Inline validation error, Ctrl-C, empty choice list, narrow terminal, no-TTY fallback (flags required), timeout | Same keystroke path, old frames against new |
| Chat-platform message or card (`chat`) | Slack Block Kit, Google Chat cardsV2, Teams Adaptive Card, Discord embed, LINE Flex; approvals, slash-command replies | P3 + P4 | Platform names, "card", "bot", "post to channel"; `@slack/bolt`, `@slack/web-api`, Google Chat API, `botbuilder`, `adaptivecards`, discord.js, `@line/bot-sdk`; keys `blocks`, `cardsV2`, `"type":"AdaptiveCard"`, `embeds`, `"type":"flex"`; webhook URLs in config | The code or JSON template that builds the payload, the bot display name and channel config, i18n strings, interaction handlers (what a click does) | Fallback text, clicked (updated in place or ephemeral), interaction failed or timed out, bot missing scope or not in channel, over-limit text, narrow mobile, thread reply | Old payload against new, in the same thread |
| AI assistant conversation (`assistant`) | In-product chatbot, a Claude Code or Codex skill or command, MCP server tools | P3 assistant layout + P7 `call` per tool call | "assistant", "agent", "MCP", "tool", "skill", "slash command"; `@modelcontextprotocol/sdk`, Python `mcp`, anthropic, openai, `ai`; `SKILL.md`, `.mcp.json`, `commands/*.md`, prompt files | Tool definitions (name, description, `inputSchema`, `outputSchema`, annotations), handler result shapes and error strings, prompt and skill text, the host's tool naming, drawn as schematic chrome | Host permission prompt, tool result with `isError: true` against a JSON-RPC error, auth required, schema validation failure, empty or oversized result, clarifying question, refusal | Old tool contract and deterministic output against new. Assistant prose stays illustrative on both sides |
| Email (`email`) | Transactional, alerts, digests, invites | P5 | "email", "mail", "unsubscribe"; `emails/`, `mailers/`, `templates/mail*`, `*.mjml`, `*.hbs`; nodemailer, `@react-email/*`, mjml, SES or SESv2 SDK, `@sendgrid/mail`, postmark, ActionMailer | The template and its text alternative, the send code (From, subject, reply-to), fixtures for variables. A provider-hosted template (template id only) needs its exported copy, or else the page says the body is not in the repo | Missing variable, long name, images blocked, dark mode (approx.), plain-text client, narrow, localized subject, unsubscribed (not sent) | Old template against new, with the same data |
| Push notification (`push`) | Mobile push, web push | P6 lock screen or banner | "push", "notify on phone", "badge"; firebase-admin messaging, web-push, apns2, node-apn, expo-notifications, OneSignal; a service-worker `showNotification`; `aps` dictionary | The payload builder (title, body, data, actions or category, collapse key or thread-id, deep link), i18n strings, the app display name | Permission denied, app in foreground, silent or data-only, grouped, truncated body, missing deep-link target, TTL expired | Old copy or payload against new, in the same frame |
| SMS or text (`sms`) | OTP, alerts, reminders | P3 bubbles + P6 preview | "SMS", "text message", "OTP"; twilio, SNS `Publish` with `PhoneNumber`, vonage, messagebird; sender-ID config | Template strings, sender ID or number config, opt-out text, link-shortener config | Segment count (Thai or emoji forces UCS-2), STOP opt-out, delivery failure, sender ID unsupported in the country (verify), link wrapping | Old text against new, with the segment count on both sides |
| OS or in-app notification (`toast`) | Toast, snackbar, banner, desktop notification, notification-centre row | P6 in-app (inside P1) or desktop | "toast", "snackbar", "banner", "bell"; react-toastify, sonner, notistack, the `Notification` API, Electron `Notification` | Toast call sites (type, text, duration, position), toast theme tokens, the notification-centre item component | Several stacked, auto-dismiss or persistent, with an action, error or success type, long text | Old toast text and type against new, at the same trigger |
| API request and response (`api`) | REST, gRPC or grpc-gateway, GraphQL, JSON-RPC | P7 `call` | "endpoint", "RPC", "status code", "mutation"; `*.proto`, `buf.yaml`, `openapi.*`, `swagger.json`, `*.graphql`; grpc, express, fastify, fastapi, apollo | Proto, OpenAPI or SDL for the shape. Handler error branches for statuses and messages. Integration-test payloads for bodies. The permission map for auth states. The JSON marshaller config for field casing | UNAUTHENTICATED or 401, PERMISSION_DENIED or 403, INVALID_ARGUMENT or 400 field violations, NOT_FOUND, FAILED_PRECONDITION, ALREADY_EXISTS or 409, version conflict, RESOURCE_EXHAUSTED or 429, DEADLINE_EXCEEDED, GraphQL partial `data` with `errors[]` | Old contract against new, for the same call. A new endpoint's Before reads "not there before" |
| Webhook or event payload (`event`) | Outgoing webhooks, RabbitMQ, SQS, Kafka or NATS messages, CloudEvents | P7 `delivery` | "publish", "consume", "event", "queue", "topic", "webhook"; amqplib, amqp-connection-manager, kafkajs, the SQS SDK, nats, cloudevents; exchange or queue names in config | The publisher struct or serializer, the consumer's parser, broker config (exchange, routing key, retry and DLQ policy), the CloudEvents attributes set in code, the signature-header code | Retry with backoff, retries exhausted to DLQ, duplicate (idempotency), out of order, schema version mismatch, bad signature, receiver 5xx or timeout | Old envelope, body and attempt timeline against new, for the same failure sequence; when the plan changes the retry policy, the timeline is the change |
| Voice or IVR (`voice`) | Phone menus, voice bots, voice-assistant skills | P8 | "IVR", "press 1", "call flow", "TTS", "Alexa"; twilio TwiML (`Say`, `Gather`), Amazon Connect flow JSON, ask-sdk, Dialogflow, Lex; `*.ssml`, VoiceXML | Prompt text and SSML in code or an exported flow, the interaction model (intents, utterances, slots), the DTMF menu map, timeouts and retry counts | No-input, no-match, max retries leading to transfer, barge-in, after-hours, invalid DTMF, misrecognition (sample) | Old prompts and branches against new, on the same path |
| Generated document or report (`document`) | PDF reports, invoices, certificates, CSV or XLSX exports, DOCX | P9 | "export", "download CSV", "PDF", "invoice", "report"; puppeteer or playwright PDF, wkhtmltopdf, weasyprint, reportlab, pdfmake, jspdf, exceljs, openpyxl, xlsx, docx templating | The template, the column list and header strings, page-size and margin config, the file-name pattern, encoding, BOM and delimiter settings | Empty, one row, page break, long cell, Thai or CJK font fallback, async large export, formula injection | Old template or columns against new, with the same rows |
| Dashboard or chart (`dashboard`) | Ops dashboards, in-app analytics, KPI tiles, alert panels | P10 | "dashboard", "chart", "panel", "metric", "KPI"; Grafana JSON (`panels`), Superset or Metabase exports, LookML, Datadog or CloudWatch dashboard JSON; recharts, chart.js, echarts, d3, visx | Panel definitions (title, query, unit, thresholds, legend, colours), metric names, chart props, fixture data | No data, query error, gap, threshold breached, too many series, timezone | Old panel config against new, with the same illustrative data |
| Infra or config plan output (`infra`) | terraform or terragrunt plan, pulumi preview, CloudFormation change set, k8s, helm or argocd diff, migrations | P11 (in P2 when a CLI prints it) | "terraform", "plan", "apply", "helm", "manifest", "migration"; `*.tf`, `terragrunt.hcl`, `Pulumi.yaml`, `Chart.yaml`, `kustomization.yaml`, `migrations/*.sql` | The IaC or manifest diff named by the plan. A plan output file the user supplies. Provider docs for which attributes force replacement (verify each one) | Replace instead of in-place, destroy present, drift, no-op, apply failure, cascade to dependents | The diff is the before and after (`view=diff`), shown in both views |
| Code-host review surface (`code-host`) | MR or PR comment, review thread, check run, commit status, CI job log | P3 thread nesting P11 or P2; a check run or job log is P2 | "MR comment", "PR comment", "post the plan"; `.gitlab-ci.yml`, `.github/workflows/*`, `atlantis.yaml`, `.tfcmt.yaml`; API calls to `notes`, `comments`, `check-runs`, `statuses` | The repo's comment template or posting script; a tool's default template is outside the repo, so its body is "not traced" unless the user pastes one | Edited in place against a new comment, collapsed `<details>`, body over the host limit (verify), job failed before posting, token missing | Old comment body against new, for the same diff |
| **Unknown surface (fallback)** | Kiosk, TV, wearable, label printer, hardware display, AR, a log line read by people | Pick by shape. Text stream: P2. Turn-taking: P3. Structured bytes: P7. Paged or printed: P9. A screen: P1 with a schematic host | Nothing matched, or two families tied | Whatever the person actually receives, read from the code that produces it. If nothing exists yet, a **"Spec card"** that renders the plan's own words, labelled "No artifact yet: from plan §X" | Derived from the producing code's error branches. Without code, only the outcomes the plan lists | Read at `base:` when the producing code exists there; otherwise Before reads "not there before" |

**Shape fallback.** When no family matches, pick the primitive by what the person receives:

| What the person receives | Primitive |
|---|---|
| text lines · turns between parties · structured bytes a program reads | P2 · P3 · P7 |
| a transient alert · a paged, printed or downloaded file · speech or tones | P6 · P9 · P8 |
| numbers over time · desired against actual state · pixels the project draws | P10 · P11 · P1 in a schematic host |
| none of these (haptic, light, motion), or nothing built yet | **Spec card**: the plan's words, each line cited `§X`, labelled "No artifact yet" or "Not drawable" |

**A surface no row matches** is settled before any cells or section worker (the tracer gathers the facts, the
main thread asks), with the five questions and
the one-question limit in `surface-mockup-contract.md` "2. Resolution"; the answers go in that surface's
SURFACE BRIEF in `_ids.md`.

### Platform facts used above

| Platform | Fact |
|---|---|
| Slack Block Kit | At most 50 blocks per message and 100 in modals or Home (verify). Section text up to 3000 chars and header up to 150 (verify). The top-level `text` is the notification fallback |
| Google Chat | `cardsV2: [{cardId, card: {header, sections: [{header, widgets: []}]}}]`. Widgets include textParagraph, decoratedText, buttonList, image, divider, grid, columns, selectionInput, textInput, dateTimePicker and chipList (verify the list). Text limit is about 4096 chars (verify) |
| Teams Adaptive Card | `"type":"AdaptiveCard"` with a `version` field. Teams clients broadly support up to 1.5 (verify per client). Elements include TextBlock, FactSet, ColumnSet, Container, Image and ActionSet. Actions include Action.Submit, Action.OpenUrl and Action.Execute. Message size is about 28 KB (verify) |
| Discord | Content up to 2000 chars. Up to 10 embeds. Title 256, description 4096, 25 fields (name 256, value 1024), footer 2048, about 6000 chars across a message's embeds (verify). Up to 5 buttons per action row and 5 rows (verify). Newer component layouts exist (verify) |
| LINE Flex | `{"type":"flex","altText":…,"contents": bubble or carousel}`. A bubble has header, hero, body and footer blocks. A carousel holds up to 12 bubbles (verify). `altText` up to 400 chars (verify). It shows in the notification and the chat list |
| Email | Gmail clips HTML over about 102 KB (verify). Preheader preview runs about 40–140 chars depending on client (verify). Remote images may be blocked by default |
| Push | APNs and FCM payloads are about 4 KB (verify). Web Push is about 4 KB (verify). Lock-screen line counts vary by OS (verify, and record the count used in the mockup) |
| SMS | GSM-7: 160 chars in one segment, 153 per segment when concatenated. UCS-2 (any Thai character or emoji): 70 and 67 |
| gRPC codes | INVALID_ARGUMENT 3, DEADLINE_EXCEEDED 4, NOT_FOUND 5, ALREADY_EXISTS 6, PERMISSION_DENIED 7, RESOURCE_EXHAUSTED 8, FAILED_PRECONDITION 9, ABORTED 10, UNIMPLEMENTED 12, INTERNAL 13, UNAVAILABLE 14, UNAUTHENTICATED 16 |
| GraphQL | Classic servers return HTTP 200 with `errors[]` and possibly partial `data`. GraphQL-over-HTTP with `application/graphql-response+json` may use 4xx for request errors, so check the server |
| REST errors | RFC 9457 `application/problem+json` carries type, title, status, detail and instance, when the project uses it |
| CloudEvents 1.0 | Required: `specversion`, `id`, `source`, `type`. Optional: `datacontenttype`, `dataschema`, `subject`, `time`. Binary or structured content mode |
| MCP | A tool result carries `content[]` and optional `structuredContent`. A tool failure is a result with `isError: true` that the model sees, distinct from a JSON-RPC `error`. Annotations: readOnlyHint, destructiveHint, idempotentHint, openWorldHint (verify against the spec revision) |
| Browser extension | Popup at most about 800x600 px (verify). Badge shows about 4 chars (verify) |
| CLI conventions | Exit 0 means success, 1 general failure, 2 usage error. These are conventions only, so read the code. Colour is off when not a TTY or when `NO_COLOR` is set, only if the tool implements it |

## 3. Faithfulness rules

The rules every primitive shares (the `Sources:` line, sample and illustrative values, gap marks, limits,
schematic host chrome) are in `surface-mockup-contract.md` "6. Provenance" and "8. Faithfulness, format and
accessibility". This section adds the source ranking and, per primitive, what must be exact and the lie to
prevent.

**Source authority, highest first:** (1) golden or snapshot tests and captured real output; (2) the code
that builds the output; (3) schema, proto or manifest; (4) docs; (5) the plan's prose (After only).

| Primitive | Must be exact | May be abstracted | Most common lie | Prevention |
|---|---|---|---|---|
| P1 Screen frame | Route path, component structure, copy and i18n strings, tokens (colour, type, spacing, radius), icons from the project's set, field order, RBAC-gated visibility | Host chrome, device status bar, data values (from fixtures) | **The designer's version:** the After drawn with spacing, components or icons the project doesn't have | Build only from existing components and tokens. A new element cites the plan section that specifies it. An unspecified one is a dashed `data-gap="unspecified"` box (`surface-mockup-contract.md` "6. Provenance") |
| P2 Terminal session | Command, subcommand and flag names, help text, every output line, column headers and alignment, colour usage, stream, exit code, prompt wording | Shell prompt and cwd, hostnames, timestamps, durations (labelled) | **Pretty output:** tables, colour, emoji and a success tone the code never prints, or exit 0 on an error path | Copy from golden files, else assemble line by line from the print calls. Show the exit code and stream on every frame |
| P3 Conversation thread | Bot display name, system-sent text, ephemeral or visible, thread placement, message order | Other people's messages (labelled sample), avatars, timestamps, channel chatter | **Invented context:** human replies or assistant prose that make the flow look smoother than it is | Only system-produced messages are exact. Human turns are "sample input". Assistant prose is "illustrative" and kept to about one line |
| P4 Rich card | Element types and order, field names, text, button labels and action ids, style hints, fallback or alt text, behaviour after a click | Vendor styling (neutral), images (placeholder), per-client pixel layout | **An impossible card:** elements the platform rejects or that exceed limits, such as too many buttons in a row or a Flex-only component in an Adaptive Card | 1:1 `data-el` mirroring, the exact Payload view, and counts and lengths checked against the limits table |
| P5 Mail message | From name and address, subject, preheader, body copy, link text, footer and unsubscribe, the plain-text part, template width | Client chrome, per-client rendering (labelled approx.), images (alt placeholder) | **The browser-perfect email:** a remote logo, web fonts, and layout that real clients break, filled with fake names | Sandboxed srcdoc of the real template. Images as alt boxes. Fixtures or visible `{{var}}` chips. An "approx." label |
| P6 Notification | Title, body, action labels, app display name, grouping key, deep-link target, trigger condition | OS chrome, icon (initials), time, line counts (verify) | **Full text where the OS truncates**, or a banner shown when the app is in the foreground and suppresses it | Clamp to the recorded line counts. Always include the foreground and permission-denied edge cards, taken from the code |
| P7 Wire exchange | Method and path or full RPC name, field names, types and casing, enum values, status name and number, error strings, required headers and metadata, envelope attributes, routing key, retry numbers | Tokens (redacted), ids (labelled sample), latency (omitted), unrelated headers | **Wrong error semantics:** a 4xx for a GraphQL error, `NOT_FOUND` where the handler returns `PERMISSION_DENIED`, or snake_case JSON where the marshaller emits lowerCamelCase | Read each edge card's error branch in the handler. Take JSON names from the marshaller config (for protojson, check `UseProtoNames` and `EmitUnpopulated`) |
| P8 Spoken dialog | Prompt text, SSML, menu digits, timeouts, retry counts, transfer targets, branch order | Voice and prosody, caller utterances (sample) | **Screen copy read aloud:** prompts written as on-screen text (lists, links, formatting), with the no-input and no-match branches skipped | Exact text with SSML chips. Every gather or intent gets no-input and no-match edge cards from config |
| P9 Document page | Paper size, margins, header and footer, column set and order, header strings, number and date formats, file name, delimiter, quoting, encoding and BOM | Row values (fixtures or sample), fonts that aren't embedded (fallback noted) | **The tidy single page:** pagination, overflow and the raw CSV bytes hidden behind a pretty table | The Raw view is always present for exports. A many-rows variant shows page 2. Formats come from the code |
| P10 Data tile | Title, unit, query or metric name, thresholds, legend names, chart type, configured colours, default time range | Values (illustrative), ticks derived from them | **A convincing trend** that implies an outcome ("latency drops after the change") | The same data on both sides, the badge, no conclusion in the caption. Use flat or neutral series unless fixtures exist |
| P11 Change-set | Resource addresses, action per resource, attribute names, repo-known old and new values, the tool's summary wording | `(known after apply)` values as the tool prints them, counts when not run (labelled expected) | **In-place where the change replaces:** an attribute that forces replacement shown as `~`, or cascaded changes left out | Without captured output, show the "Expected, not run" badge and mark unverified attributes "(verify: may force replacement)". Ask for a real plan file when it matters |
