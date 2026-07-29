# Claude Code Customization Artifact Catalog

**Purpose:** Precise, copy-paste-ready reference for `harvest-automations`. Read this file to determine which artifact to create or update and how to do it safely.

---

## 1. Skill (`skills/<name>/SKILL.md`)

### What it is
A named, invocable playbook (via `Skill` tool or `/name`) that encodes multi-step procedures too long for inline instructions.

**Use this when:** The same multi-step procedure is observed more than twice across sessions — research workflows, code patterns, inspection sequences, design review flows.

### On-disk location

| Scope | Path |
|-------|------|
| User (global) | `~/.claude/skills/<name>/SKILL.md` |
| Project | `<repo>/.claude/skills/<name>/SKILL.md` |
| Plugin | `<plugin-root>/skills/<name>/SKILL.md` |

Plugin skills are namespaced: shown in system-reminder as `<plugin>:<name>`.

### File format / template

```markdown
---
name: <slug-matching-directory-name>
description: <one-line shown in skill list and Skill tool description>
version: <semver, optional>
---

# <Human Title>

## When to use
- <trigger phrase or condition>
- <another trigger>

## When NOT to use
- <anti-pattern>

## Steps

### Step 1 — <title>
<instructions>

### Step 2 — <title>
<instructions>
```

**Frontmatter fields:** `name` (required), `description` (required), `version` (optional).

### CREATE mechanic

```bash
mkdir -p ~/.claude/skills/<name>
cat > ~/.claude/skills/<name>/SKILL.md << 'EOF'
---
name: <name>
description: <description>
---

# <Title>

## When to use
- <trigger>

## Steps
### Step 1 — <title>
<body>
EOF
```

### UPDATE / merge recipe

Read the file, append a new `## <Section>` heading with the additional content, then write back. Never clobber existing sections — add beneath the last `##` heading.

```bash
# Pattern: append a new section to an existing SKILL.md
skill_file="$HOME/.claude/skills/<name>/SKILL.md"
cp "$skill_file" "${skill_file}.bak.$(date +%s)"
cat >> "$skill_file" << 'EOF'

## <New Section>
<content>
EOF
```

To update frontmatter fields, use `sed` or re-write the whole file after reading it.

### Load / activation

Immediate — available on the next `Skill` tool call or `/name` invocation in the same session. No restart needed.

---

## 2. Slash Command (`commands/<name>.md`)

### What it is
A user-invocable `/name` shortcut that is injected as a system prompt when typed. Supports `$ARGUMENTS` (full remainder) and positional `$1`, `$2`, etc.

**Use this when:** A repeatable action can be triggered by a short typed phrase — one-liners like `/battery`, `/ship`, or argument-accepting templates like `/plan [topic]`.

### On-disk location

| Scope | Path |
|-------|------|
| User (global) | `~/.claude/commands/<name>.md` |
| Project | `<repo>/.claude/commands/<name>.md` |
| Plugin | `<plugin-root>/commands/<name>.md` |

Plugin commands are namespaced: `/plugin-name:command-name`.

### File format / template

```markdown
---
description: <one-line description shown in autocomplete>
argument-hint: <shown after the slash command in autocomplete, e.g. [optional arg]>
allowed-tools: [Bash, Read, Write, Edit, Skill, Task]
---

# <Command Title>

<Body — injected verbatim as instructions when the command is invoked.>
<Use $ARGUMENTS to refer to everything typed after the slash command.>
<Use $1, $2 for positional arguments.>

Arguments provided: $ARGUMENTS
```

**Frontmatter fields:** `description` (required for display), `argument-hint` (optional), `allowed-tools` (optional list).

### CREATE mechanic

```bash
cat > ~/.claude/commands/<name>.md << 'EOF'
---
description: <description>
argument-hint: [optional-arg]
---

# <Title>

<instructions using $ARGUMENTS>
EOF
```

### UPDATE / merge recipe

Append or rewrite sections. Commands are single-file; read then write back.

```bash
cmd="$HOME/.claude/commands/<name>.md"
cp "$cmd" "${cmd}.bak.$(date +%s)"
# Edit with sed or full rewrite after Read
```

### Load / activation

Immediate — the command appears in autocomplete and is callable in the same session without restart.

---

## 3. Subagent (`agents/<name>.md`)

### What it is
A sandboxed Claude instance with its own system prompt, tool list, model selection, and optional color label. Invoked via the `Agent` tool's `subagent_type` parameter.

**Use this when:** A task needs isolation (its own context, specific tools only, a different model tier), recurring role-based specialization (reviewer, Jira updater, platform explorer), or when the orchestrator should delegate rather than do.

### On-disk location

| Scope | Path |
|-------|------|
| User (global) | `~/.claude/agents/<name>.md` |
| Project | `<repo>/.claude/agents/<name>.md` |
| Plugin | `<plugin-root>/agents/<name>.md` |

### File format / template

```markdown
---
name: <slug>
description: >
  <Multi-line description — shown in Agent tool enum. First sentence is used
  for matching. Include trigger phrases for auto-selection.>
tools: Read, Grep, Glob, Bash, Write, Edit, mcp__<server>__<tool>
model: <opus|sonnet|haiku|claude-opus-4-5-20251001|claude-haiku-4-5-20251001>
effort: <low|medium|high>
color: <purple|blue|green|yellow|red|gray>
---

# <Agent Title>

## Purpose
<What this agent does and why it exists.>

## Inputs
<What context/files/arguments it expects when invoked.>

## Output contract
<What it produces — file paths, return format, side effects.>

## Steps
<Numbered instructions the agent follows.>
```

**Frontmatter fields:**
- `name` (required) — matches slug; surfaces as `subagent_type` value in `Agent` tool
- `description` (required) — governs auto-selection; include trigger keywords
- `tools` (required) — comma-separated allowlist
- `model` (optional) — full model ID or shorthand; defaults to session model
- `effort` (optional) — `low|medium|high`; maps to thinking budget
- `color` (optional) — terminal badge color

### CREATE mechanic

```bash
cat > ~/.claude/agents/<name>.md << 'EOF'
---
name: <name>
description: <description with trigger keywords>
tools: Read, Grep, Glob, Bash
model: sonnet
---

# <Title>

## Purpose
<purpose>

## Steps
1. <step>
EOF
```

### UPDATE / merge recipe

Whole-file type. Read → add/edit section → write back. To add tools:

```bash
agent="$HOME/.claude/agents/<name>.md"
cp "$agent" "${agent}.bak.$(date +%s)"
# Use sed to patch the tools line, or full rewrite
sed -i '' 's/^tools: .*/tools: Read, Grep, Glob, Bash, Write, Edit/' "$agent"
```

### Load / activation

Immediate — the new `subagent_type` value is available to the `Agent` tool in the same session.

---

## 4. Hook (`settings.json` → `hooks`)

### What it is
A shell command triggered automatically at a lifecycle event. The harness (not Claude) executes hooks; they run outside the model context.

**Use this when:** A behavior must trigger on every occurrence of an event regardless of what Claude is doing — window title updates, permission guards, automatic status updates, pre/post tool enforcement, session initialization.

### On-disk location

| Scope | File |
|-------|------|
| User (global) | `~/.claude/settings.json` → `.hooks` |
| Project | `<repo>/.claude/settings.json` → `.hooks` |
| Plugin | `<plugin-root>/hooks/hooks.json` → `.hooks` (merged by plugin loader) |

### Supported events

| Event | Fires |
|-------|-------|
| `PreToolUse` | Before any tool call; `matcher` = tool name (e.g. `Bash`, `Write`, `Edit`, `Read`, `Grep`, `Glob`, `Task`, `ExitPlanMode`, `EnterPlanMode`, `NotebookEdit`) |
| `PostToolUse` | After a tool call; same matchers |
| `UserPromptSubmit` | When the user submits a prompt; matcher `*` = all |
| `Stop` | When Claude stops generating |
| `SessionStart` | On session open |
| `Notification` | When a desktop notification would fire |
| `PermissionRequest` | When a permission check triggers (plugin hooks.json only) |

### File format / template

```json
{
  "hooks": {
    "<Event>": [
      {
        "matcher": "<ToolName|*>",
        "hooks": [
          {
            "type": "command",
            "command": "bash /absolute/path/to/script.sh",
            "timeout": 10
          }
        ]
      }
    ]
  }
}
```

**Hook object fields:** `type` (always `"command"`), `command` (absolute path recommended), `timeout` (seconds, optional, default varies).

Hook scripts communicate back to Claude via stdout (JSON or plain text) and exit codes:
- exit 0 = allow / no-op
- exit 1 + non-empty stdout = block and show message to Claude
- stdout JSON `{"decision": "block", "reason": "..."}` = structured block

### CREATE mechanic (minimal valid hook)

```bash
settings="${CLAUDE_CONFIG_DIR:-$HOME/.claude}/settings.json"
bak="${settings}.bak.$(date +%s)"; cp "$settings" "$bak"
jq '.hooks["UserPromptSubmit"] = [{"matcher": "*", "hooks": [{"type": "command", "command": "bash /path/to/script.sh", "timeout": 5}]}]' \
  "$settings" > /tmp/s.json && jq empty /tmp/s.json && mv /tmp/s.json "$settings"
```

### UPDATE / merge recipe

**Merge into existing event array without clobbering:**

```bash
settings="${CLAUDE_CONFIG_DIR:-$HOME/.claude}/settings.json"
bak="${settings}.bak.$(date +%s)"; cp "$settings" "$bak"

NEW_HOOK='{"type":"command","command":"bash /path/to/new-script.sh","timeout":10}'

# Add hook to an existing matcher entry, or create new matcher entry
jq --arg event "PreToolUse" \
   --arg matcher "Bash" \
   --argjson h "$NEW_HOOK" \
   '
   if .hooks[$event] then
     .hooks[$event] |= map(
       if .matcher == $matcher
       then .hooks += [$h]
       else .
       end
     )
     | if (.hooks[$event] | map(select(.matcher == $matcher)) | length) == 0
       then .hooks[$event] += [{"matcher": $matcher, "hooks": [$h]}]
       else .
       end
   else
     .hooks[$event] = [{"matcher": $matcher, "hooks": [$h]}]
   end
   ' "$settings" > /tmp/s.json \
&& jq empty /tmp/s.json \
&& mv /tmp/s.json "$settings" \
|| { echo "ABORT: jq failed, restoring backup"; cp "$bak" "$settings"; }
```

For plugin `hooks/hooks.json`, same structure but scoped to the plugin directory — the plugin loader merges it.

### Load / activation

Takes effect at the **next prompt submission** (for `UserPromptSubmit`) or **next tool call** (for `Pre/PostToolUse`). No restart required for user-scope hooks. Plugin hooks load on plugin activation.

---

## 5. Permission (`settings.json` → `permissions.allow` / `permissions.deny`)

### What it is
An explicit allow or deny rule that pre-approves (or blocks) a tool invocation pattern, eliminating interactive permission prompts.

**Use this when:** Claude repeatedly asks for permission for the same command; or a dangerous command class should always be blocked without prompting.

### On-disk location

| Scope | File |
|-------|------|
| User (global) | `~/.claude/settings.json` → `.permissions.allow` / `.permissions.deny` |
| Project | `<repo>/.claude/settings.json` → same |
| Project (local, git-ignored) | `<repo>/.claude/settings.local.json` → same |

`defaultMode` values: `"default"` (prompt), `"bypassPermissions"` (no prompts), `"acceptEdits"` (edits auto-accepted, bash prompts).

### File format / template

```json
{
  "permissions": {
    "allow": [
      "Bash(git log:*)",
      "Bash(npm run test:*)",
      "Bash(docker build:*)",
      "Read(**)",
      "WebFetch(*)"
    ],
    "deny": [
      "Bash(rm -rf:*)"
    ],
    "defaultMode": "default"
  }
}
```

**Pattern syntax:**
- `Bash(<prefix>:*)` — match any Bash command starting with `<prefix>`
- `Bash(<exact command>)` — exact match
- `Read(<glob>)` — file read by glob
- `WebFetch(<url-pattern>)` — URL prefix or glob
- Tool name alone (e.g., `"Write"`) — allow all uses of that tool

### CREATE mechanic (add first rule)

```bash
settings="${CLAUDE_CONFIG_DIR:-$HOME/.claude}/settings.json"
bak="${settings}.bak.$(date +%s)"; cp "$settings" "$bak"
jq '.permissions.allow += ["Bash(npm run build:*)"] | .permissions.allow |= unique' \
  "$settings" > /tmp/s.json && jq empty /tmp/s.json && mv /tmp/s.json "$settings"
```

### UPDATE / merge recipe

**Add to allow list without duplicates:**

```bash
settings="${CLAUDE_CONFIG_DIR:-$HOME/.claude}/settings.json"
bak="${settings}.bak.$(date +%s)"; cp "$settings" "$bak"

NEW_PERM='Bash(kubectl get:*)'

jq --arg p "$NEW_PERM" \
  '.permissions.allow += [$p] | .permissions.allow |= unique' \
  "$settings" > /tmp/s.json \
&& jq empty /tmp/s.json \
&& mv /tmp/s.json "$settings" \
|| { echo "ABORT"; cp "$bak" "$settings"; }
```

**Add to deny list:**

```bash
jq --arg p 'Bash(rm -rf:*)' \
  '.permissions.deny += [$p] | .permissions.deny |= unique' \
  "$settings" > /tmp/s.json && jq empty /tmp/s.json && mv /tmp/s.json "$settings"
```

**Set defaultMode:**

```bash
jq '.permissions.defaultMode = "bypassPermissions"' \
  "$settings" > /tmp/s.json && jq empty /tmp/s.json && mv /tmp/s.json "$settings"
```

Project-scoped rules go in `<repo>/.claude/settings.json`. Secret-safe project rules (not committed) go in `<repo>/.claude/settings.local.json`.

### Load / activation

Immediate — applies to the next tool call in the same session.

---

## 6. CLAUDE.md / Memory

### What it is
**CLAUDE.md** — persistent instruction file read at session start; sets standing behaviors, preferences, and conventions. **Memory files** — individual `.md` files in `~/.claude/memory/` (or project `<repo>/.claude/memory/`) indexed by `MEMORY.md`; Claude writes these to persist observations across sessions.

**Use this when:** A behavior, preference, or constraint should persist across every session (CLAUDE.md), or a specific observation from a session should be recalled later (memory file).

### On-disk location

| Artifact | Scope | Path |
|----------|-------|------|
| CLAUDE.md | User (global) | `~/.claude/CLAUDE.md` |
| CLAUDE.md | Project | `<repo>/CLAUDE.md` or `<repo>/.claude/CLAUDE.md` |
| Memory file | User | `~/.claude/memory/<topic>.md` |
| Memory file | Project | `<repo>/.claude/memory/<topic>.md` |
| Memory index | User | `~/.claude/MEMORY.md` |
| Memory index | Project | `<repo>/.claude/MEMORY.md` |

`@import <path>` in CLAUDE.md pulls in another file's content at load time.

### File format / templates

**CLAUDE.md section append:**

```markdown
## <Topic Heading>

<Standing instruction text. Be imperative and specific.>

- **Rule:** <concrete directive>
- **When:** <trigger condition>
- **Why:** <motivation — helps Claude apply it correctly>
```

**Memory file frontmatter:**

```markdown
---
name: <Human-readable title>
description: <One-line; shown in memory index entries>
type: <user|feedback|project|reference>
---

<Body — the observation, preference, or fact to remember.>

**Why:** <motivation>

**How to apply:** <concrete usage instructions>
```

**`type` values:**
- `user` — personal preferences and working style
- `feedback` — corrections from past sessions
- `project` — project-specific facts and conventions
- `reference` — reference data (account maps, credentials metadata, etc.)

**MEMORY.md index line format:**

```markdown
- [<name>](memory/<filename>.md) — <one-line description>
```

### CREATE mechanic

**New memory file + index registration:**

```bash
mem_file="$HOME/.claude/memory/<topic>.md"
mem_index="$HOME/.claude/MEMORY.md"

cat > "$mem_file" << 'EOF'
---
name: <Name>
description: <description>
type: <type>
---

<body>
EOF

# Append index line
echo "- [<Name>](memory/<topic>.md) — <description>" >> "$mem_index"
```

**Append section to CLAUDE.md:**

```bash
claude_md="$HOME/.claude/CLAUDE.md"
cp "$claude_md" "${claude_md}.bak.$(date +%s)"
cat >> "$claude_md" << 'EOF'

## <New Topic>

<instructions>
EOF
```

### UPDATE / merge recipe

CLAUDE.md: append a new `## heading` section. Do not edit existing sections unless correcting them — additions are safer than rewrites.

Memory files: whole-file type. Read → update body → write back. Update the MEMORY.md index line description if the name changes.

```bash
# Update a memory file body (whole-file rewrite)
mem_file="$HOME/.claude/memory/<topic>.md"
cp "$mem_file" "${mem_file}.bak.$(date +%s)"
# Write the updated content
```

### Load / activation

CLAUDE.md: read at **session start** — changes take effect after `/clear` or a new session. Memory files: read on demand by Claude when relevant; index is consulted each session. No restart needed for memory files added mid-session if Claude re-reads the index.

---

## 7. Path-scoped Rule (`.claude/rules/<topic>.md`)

### What it is
A scoped instruction file that applies only when Claude is working on files matching a `paths:` glob. More targeted than CLAUDE.md global instructions.

**Use this when:** A rule should apply only to a specific directory or file type — e.g., "never use `any` in TypeScript files", "all SQL files must have migration rollback", "frontend components require Storybook story".

### On-disk location

| Scope | Path |
|-------|------|
| Project | `<repo>/.claude/rules/<topic>.md` |
| User (global) | `~/.claude/rules/<topic>.md` |

No plugin-scope for rules in current Claude Code versions (v1).

### File format / template

```markdown
---
description: <one-line — what this rule enforces>
paths:
  - "src/**/*.ts"
  - "src/**/*.tsx"
  - "!src/**/*.test.ts"
globs: "src/**/*.ts"
---

# <Rule Title>

<Standing instructions that apply only when working on files matching the paths above.>

- <Specific directive>
- <Another directive>

## Rationale
<Why this rule exists — helps Claude apply it correctly in edge cases.>
```

**Frontmatter fields:**
- `description` (recommended)
- `paths` (array of globs) OR `globs` (single string or array) — activates rule when a matched file is in context
- Negation prefix `!` excludes patterns

### CREATE mechanic

```bash
mkdir -p <repo>/.claude/rules
cat > <repo>/.claude/rules/<topic>.md << 'EOF'
---
description: <description>
paths:
  - "<glob>"
---

# <Title>

<rules>
EOF
```

### UPDATE / merge recipe

Append-section type. Add new directives under a new `##` heading, or update the `paths:` frontmatter array.

```bash
rule="<repo>/.claude/rules/<topic>.md"
cp "$rule" "${rule}.bak.$(date +%s)"
# Append new section
cat >> "$rule" << 'EOF'

## <Additional Rule Section>
<content>
EOF
```

To update `paths:` glob, read the frontmatter, edit, write back whole file.

### Load / activation

Immediate within the session when a matching file enters context. Takes full effect at the next prompt after the file is read.

---

## 8. MCP Server (`.mcp.json` / `mcpServers`)

### What it is
Configuration entry that registers an external tool server (Model Context Protocol). Adds new tool namespaces (e.g., `mcp__thanos-mcp__*`) to Claude's tool list.

**Use this when:** An external service provides tools via MCP — Jira, databases, custom APIs, monitoring systems, internal platforms.

### On-disk location

| Scope | Path |
|-------|------|
| User (global) | `~/.claude/.mcp.json` |
| Project | `<repo>/.mcp.json` |

Secrets in project `.mcp.json` should be `<PLACEHOLDER>` — real values go in `<repo>/.mcp.local.json` (git-ignored) or environment variables.

### File format / template

**stdio variant (local process):**

```json
{
  "mcpServers": {
    "<server-name>": {
      "command": "npx",
      "args": ["-y", "@modelcontextprotocol/<package>", "--arg"],
      "env": {
        "API_KEY": "<PLACEHOLDER>",
        "BASE_URL": "<https://example.com>"
      }
    }
  }
}
```

**HTTP/SSE variant (remote server):**

```json
{
  "mcpServers": {
    "<server-name>": {
      "type": "http",
      "url": "https://<host>/mcp",
      "headers": {
        "Authorization": "Bearer <PLACEHOLDER_TOKEN>"
      }
    }
  }
}
```

**Key shape differences:**
- stdio: `command` (string), `args` (array), `env` (object) — no `type` field needed
- http: `type: "http"`, `url`, `headers` — no `command`/`args`/`env`

### CREATE mechanic

```bash
mcp="${CLAUDE_CONFIG_DIR:-$HOME/.claude}/.mcp.json"
bak="${mcp}.bak.$(date +%s)"; cp "$mcp" "$bak"

NEW_SERVER='{
  "type": "http",
  "url": "https://example.com/mcp",
  "headers": {"Authorization": "Bearer <PLACEHOLDER>"}
}'

jq --arg name "my-server" --argjson s "$NEW_SERVER" \
  '.mcpServers[$name] = $s' "$mcp" > /tmp/m.json \
&& jq empty /tmp/m.json \
&& mv /tmp/m.json "$mcp" \
|| { echo "ABORT"; cp "$bak" "$mcp"; }
```

### UPDATE / merge recipe

**Add or replace a single server (merge-json, safe):**

```bash
mcp="${CLAUDE_CONFIG_DIR:-$HOME/.claude}/.mcp.json"
bak="${mcp}.bak.$(date +%s)"; cp "$mcp" "$bak"

UPDATED_SERVER='{
  "command": "node",
  "args": ["/path/to/server.js"],
  "env": {"TOKEN": "<PLACEHOLDER>"}
}'

jq --arg name "<server-name>" --argjson s "$UPDATED_SERVER" \
  '.mcpServers[$name] = $s' "$mcp" > /tmp/m.json \
&& jq empty /tmp/m.json \
&& mv /tmp/m.json "$mcp" \
|| { echo "ABORT"; cp "$bak" "$mcp"; }
```

**Remove a server:**

```bash
jq 'del(.mcpServers["<server-name>"])' "$mcp" > /tmp/m.json \
&& jq empty /tmp/m.json && mv /tmp/m.json "$mcp"
```

**SECURITY:** Never put real tokens in project-committed `.mcp.json`. Use `<PLACEHOLDER>` and load secrets from `~/.claude/.env` (chmod 600, git-ignored) or environment variables at runtime.

### Load / activation

Requires **session restart** — MCP servers are connected at session open. After editing `.mcp.json`, start a new Claude Code session to pick up the change.

---

## 9. Output Style (`output-styles/<name>.md`)

### What it is
A named response style preset that overrides Claude's default formatting. Applied via the `output-styles` setting or invoked by a skill/command.

**Use this when:** A recurring output format is observed — always-markdown, concise-bullets, verbose-prose, emoji-free, table-heavy reporting. Codifies "respond like X" instructions as a reusable preset.

### On-disk location

| Scope | Path |
|-------|------|
| User (global) | `~/.claude/output-styles/<name>.md` |
| Project | `<repo>/.claude/output-styles/<name>.md` |
| Plugin | `<plugin-root>/output-styles/<name>.md` |

### File format / template

```markdown
---
name: <slug>
description: <one-line — when to use this style>
---

# <Style Name>

<System-prompt-style instructions that govern response formatting.>

## Format rules
- <Rule: e.g., "Use bullet points, not paragraphs, for lists of 3+ items">
- <Rule: e.g., "Never use emoji unless the user uses them first">
- <Rule: e.g., "Code snippets always in fenced blocks with language tag">
- <Rule: e.g., "Limit prose paragraphs to 3 sentences">

## Tone
<Tone guidance: concise/verbose/formal/casual>

## Structure
<Structure guidance: headers/no-headers, table preference, etc.>
```

**Frontmatter fields:** `name` (required), `description` (required).
The body is injected as a system-level style constraint.

### CREATE mechanic

```bash
mkdir -p ~/.claude/output-styles
cat > ~/.claude/output-styles/<name>.md << 'EOF'
---
name: <name>
description: <description>
---

# <Style Name>

## Format rules
- <rule>

## Tone
<tone>
EOF
```

### UPDATE / merge recipe

Whole-file type — styles are self-contained presets. Read → edit sections → write back.

```bash
style="$HOME/.claude/output-styles/<name>.md"
cp "$style" "${style}.bak.$(date +%s)"
# Edit: append new rule under ## Format rules, or rewrite section
```

To append one rule without full rewrite:

```bash
sed -i '' '/^## Format rules/a\\- <new rule>' "$style"
```

### Load / activation

Immediate — applies to the next response after the style is referenced by name or the setting is updated.

---

## Deferred in V1

### Full Plugin (versioned distribution)
A plugin is a directory with `.claude-plugin/plugin.json` (name, description, version, author), a `hooks/hooks.json`, `skills/`, `commands/`, `agents/`, and optional `output-styles/`. Plugins are registered in a `marketplace.json` and loaded via `settings.json` → `enabledPlugins`. Harvest only **suggests** plugin bundling — it does not auto-generate the full plugin structure because version management, marketplace registration, and the publish flow (`/publish-plugin` skill) require human decisions about versioning strategy, distribution channel, and author metadata. Auto-generating a partial plugin risks creating an invalid registration that breaks the plugin loader.

### Keybindings (`~/.claude/keybindings.json`)
Maps key chords to Claude Code actions. Harvest only **suggests** — keybindings are highly personal, may conflict with existing bindings, and the `/keybindings-help` skill (which reads live binding state) is the correct editor for this file. Auto-generating keybindings without conflict-checking would silently shadow existing shortcuts.

### Monitors (plugin-only, `EnterWorktree`/`ExitWorktree`)
Monitor scripts observe background processes and stream events. Plugin-scope only. Harvest only **suggests** — monitors require understanding of the specific process being watched, and incorrect monitor scripts can flood the session with noise. Manual implementation via the `Monitor` tool is safer for one-off use.

### statusLine (`settings.json` → `statusLine`)
Configures the terminal status bar command. Harvest only **suggests** — the status line command is an ergonomic preference tied to the user's terminal setup, session ID scheme, and shell environment. Auto-replacing it would silently break a working status bar. The user should confirm the command before it is written.

---

## Consolidated Decision Rubric

> The `harvest-automations` skill greps this table for the recommended artifact and strategy.

| Recurring pattern observed | Best artifact | Create/Update strategy | Load |
|---|---|---|---|
| Same multi-step procedure executed manually 2+ times | **Skill** | whole-file (new) or append-section (extend) | Immediate |
| Same `/command` phrase typed repeatedly with same intent | **Slash command** | whole-file (new or rewrite) | Immediate |
| Task that benefits from isolation, dedicated tools, or a different model | **Subagent** | whole-file (new) or whole-file (update tools/model) | Immediate |
| "Every time X happens, run Y automatically" (regardless of what Claude is doing) | **Hook** | merge-json into `.hooks[Event]` array | Next prompt/tool call |
| Claude keeps prompting for permission for the same command | **Permission allowlist** | merge-json: `jq '.permissions.allow += [$p] \| unique'` | Immediate |
| Standing behavior, preference, or convention that should always apply | **CLAUDE.md section** | append-section under new `##` heading | Next session (`/clear`) |
| One-off observation to recall in future sessions | **Memory file** | whole-file (new) + append MEMORY.md index line | On-demand recall |
| Rule that should only fire for specific file types/paths | **Path-scoped rule** | whole-file (new) or append-section (add paths/directives) | Next file-in-context |
| New external service / tool namespace needed | **MCP server** | merge-json: `jq '.mcpServers[$name] = $s'` | Session restart required |
| Response format that is requested repeatedly ("always respond as…") | **Output style** | whole-file (new) or append-section (add rules) | Immediate |

---

## Composing usage bundles

One **usage** (a complete user-facing workflow) may need several artifacts working together. The
governing rule is **minimality**: a bundle is the smallest set of artifacts that delivers the
usage — every artifact must be load-bearing for the workflow.

**Legitimate pairings:**

- **command + permission** — a slash command whose steps would otherwise trigger approval prompts.
- **command + subagent** — a thin parameterized entry point that dispatches heavy/isolated work
  off the main thread.
- **skill + hook** — a playbook plus a deterministic trigger that must always fire on an event.
- **mcp-server + permission** — a new server plus the allow rules its tools need.

**Anti-patterns:**

- **Never bundle a skill and a command that duplicate the same steps.** A command may only
  accompany a skill as a thin parameterized entry point that delegates to it ("Follow the
  `<skill>` skill with $ARGUMENTS") — the steps live in exactly one place.
- **`claude-md` / `rule` entries rarely justify a bundle of their own** — they usually ride along
  inside another usage as a one-line convention, not as a separate user choice.
- Don't add a subagent for work the main thread does in one or two tool calls — isolation must buy
  something (context size, parallelism, or tool restriction).

---

## Sources

The following `code.claude.com/docs` pages were used to ground this document. Some details (especially `effort` field support and `PermissionRequest` event) are version-dependent and should be re-verified against current docs if behavior is unexpected.

- Memory: `https://code.claude.com/docs/en/memory.md`
- Skills: `https://code.claude.com/docs/en/skills.md`
- Sub-agents: `https://code.claude.com/docs/en/sub-agents.md`
- Hooks guide: `https://code.claude.com/docs/en/hooks-guide.md`
- Settings: `https://code.claude.com/docs/en/settings.md`
- MCP: `https://code.claude.com/docs/en/mcp.md`
- Output styles: `https://code.claude.com/docs/en/output-styles.md`
- Plugins: `https://code.claude.com/docs/en/plugins.md`
- Commands (slash): `https://code.claude.com/docs/en/slash-commands.md`

> **Version note:** The `effort` frontmatter field in subagents, the `PermissionRequest` hook event (seen live in `hooks.json`), and `output-styles` directory support are observed on the current install but may not be documented in all doc versions. Treat these as confirmed-by-observation rather than doc-confirmed.
