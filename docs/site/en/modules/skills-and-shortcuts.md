---
title: Skills & Shortcuts
description: Give the model "specialized capability bundles" and "system automation" — Agent Skills teach it to write SQL / draw / run flows; Shortcut Tools let it trigger iOS Shortcuts.
---

# Skills & Shortcuts

[Tools & MCP](/en/modules/tools-and-mcp) covers "how the AI uses tools." This page covers two lighter-weight ways to extend the AI:

- **Agent Skills** — bundle "instructions + resources" into a folder the AI can read and follow step by step
- **Shortcut Tools** — expose your iOS Shortcuts as callable tools

Both work **without writing any code**, lower-barrier than MCP.

## What Each Solves

### Agent Skills Solve the "Prompt Engineering" Problem

If you keep asking the AI to do similar things — write emails to company spec, analyze data and produce charts, refactor Swift to your style — pasting the rules every time gets old.

A **Skill pack** is a folder containing:

- `SKILL.md` — the core spec (name, description, when to use, step-by-step)
- Any number of resource files (templates, references, examples, and optional `scripts/`)

In chat, the AI sees "you have these Skills available" and proactively reads `SKILL.md` when it needs to follow that recipe.

### Shortcut Tools Solve the "iOS Integration" Problem

iOS Shortcuts already do a lot — check battery, send a text, control home, read calendar, run Python (via a-Shell, etc.).

**Shortcut Tools** wrap them as callable tools for the AI. "Check today's calendar" makes the AI call the relevant Shortcut; the result flows back as part of its response.

## Read This First

### Agent Skills

#### Where

```
Settings → Agent Skills
```

Top of the page is the master switch: **"Expose Agent Skills to Model (use_skill)"**.

::: warning `use_skill` and Script Execution
Regular chat still uses `use_skill` to read `SKILL.md` and resources on demand. A Skill's `scripts/` can run only in **Agent mode** with **local Linux** enabled, subject to user approval and command safety rules. Execution uses the version frozen for that Agent Run and mounts it read-only inside Linux; it does not expose the host filesystem.

With the OpenAI Responses format, ETOS uses the native local Shell and attaches enabled Skills to that Shell environment. Other formats continue through `use_skill` and its `execute_script` action. Both paths reuse ETOS's Linux isolation, writable workspace, and approval system.
:::

#### Four Import Methods

| Method | When to use |
| --- | --- |
| **Paste SKILL.md** | You've written a SKILL.md and want to paste it directly |
| **Import from GitHub** | A Skill pack lives in a GitHub repo. Paste the URL (`/tree/branch` + subpaths supported) |
| **Link Import** | Any directly-downloadable URL to a `SKILL.md` or `.zip` |
| **From local pack** | Pick a `.zip` from the iOS Files app |

#### What SKILL.md Looks Like

`SKILL.md` is a Markdown file with YAML frontmatter. Minimal structure:

```markdown
---
name: Email Helper (corporate style)
description: Writes Chinese / English business emails per company spec — opening salutations, signature, CC rules
---

# When to Use

When the user says "write an email to X" or "help me reply to this email."

# Steps

1. Ask the user: purpose, recipient language, CC?
2. Generate the body using the template…
3. …

# Template

Dear {Recipient},
...
```

ETOS only requires `name` (unique) and `description` in the frontmatter.

#### Using It

After import:

1. Per-Skill toggle: open the Skill row → enable **"Use in Chat"**
2. The AI sees: "You have N Skills available: Email Helper, Code Style, …"
3. When a Skill is relevant, the AI reads it through `use_skill`; OpenAI Responses in Agent + Linux loads the same frozen pack through native Skills

#### Skill Files

Each Skill is a directory. Besides SKILL.md you can drop in any files (images, code samples, config templates). The detail page lets you:

- Browse the file list
- Add / edit / delete files

### Shortcut Tools

#### Where

```
Settings → Shortcut Tool Integration
```

Master switch: **"Expose Shortcut Tools to Model"**.

#### How to Connect a Shortcut

ETOS uses a **bridge shortcut** to invoke any of your Shortcuts. Overall flow:

**Step 1: Install the official bridge shortcut**

The page has **"Download Official Import Shortcut"**. Tap to install ETOS's prebuilt bridge into the iOS Shortcuts app.

**Step 2: Build (or download) your own Shortcuts**

Open Apple's Shortcuts app and create or grab a Shortcut (e.g., "Today's Weather", "Read Current Location"). The Shortcut must:

- Accept text input (the AI's arguments)
- Return text output (back to the AI)

**Step 3: Tell ETOS about your Shortcuts**

The integration page has **"Import Manifest from Clipboard"**. The manifest is a JSON/YAML snippet listing the Shortcuts you want the AI to be able to call, with name, description, and parameters.

Alternatively, **"Detect and Run Import Shortcut"** asks iOS to run the bridge once and have it report your Shortcut library back to ETOS.

#### Run Mode

Each Shortcut tool has a **Run Mode** field that decides invocation:

- **Direct** — URL Scheme straight to the target Shortcut (fast, but a visible cross-app jump)
- **Bridge** — call the official bridge Shortcut, which proxies (more stable, slightly slower cross-app)

> Default order is "Direct → Bridge"; setting a tool's run mode to Bridge reverses it.

Leave it at default unless you know what you're doing.

#### Auto-Approve Countdown

Shortcut tools use the same approval policy as [Tools & MCP](/en/modules/tools-and-mcp), with extras:

| Field | Effect |
| --- | --- |
| Enable Auto-Approve Countdown | The approval bubble auto-approves after N seconds if you don't act |
| Countdown Seconds | Adjustable |
| Disabled Auto-Approve Tools | Tools you specifically want **never** auto-approved |

::: warning Auto-Approve Is Sharp
If your Shortcuts include "send message", "send email", "control home", **don't enable auto-approve**. The AI will occasionally fire side-effectful actions you didn't explicitly OK.
:::

## Advanced

### Skills vs Tools — When to Use Which

| Dimension | Agent Skills | MCP / App Tools |
| --- | --- | --- |
| Nature | Skill pack (docs + resources + optional scripts) | Code / service |
| Authoring | Markdown | Code or server deployment |
| Best for | Flows, rules, templates | Live data, external APIs, file ops |
| Examples | Email templates, code style guides, writing style | Weather, file read, GitHub API |

**Rule of thumb**: if "the AI knows how, just needs your conventions" → Skill. If "the AI literally doesn't know the answer and needs to query something" → Tool/MCP.

### Skills on GitHub

The community has many public Skill repos. The GitHub import supports:

- Top-level: auto-detects `SKILL.md`
- `/tree/branch/path/to/skill/`: specific branch and subpath
- Whole repo: traverse every subdir with a `SKILL.md` and batch-import

### URL Scheme for Shortcut Tools

To trigger an ETOS Shortcut tool from outside iOS:

```
etos-llm-studio://shortcut-tool?name=ToolName&input=Text
```

Full scheme protocol is documented under Extended Features.

### `allowed-tools` in SKILL.md

`SKILL.md` frontmatter may list `allowed-tools`. Once that Skill is loaded in the current chat run, ETOS uses the list to filter ordinary tools both when exposing them and immediately before execution; unlisted tools are rejected.

`allowed-tools` can only subtract from tools already enabled for the session. It cannot add tools, enable a disabled integration, bypass approvals, or act as a Shell command allowlist. Omitting it adds no extra restriction, and the restriction is released when the current run ends.

## Next

- Connect external data → [Tools & MCP](/en/modules/tools-and-mcp)
- Long-term memory → [Memory & Worldbook](/en/modules/memory-worldbook)
- Clever combos → [Hidden Gems](/en/tips/hidden-gems)
