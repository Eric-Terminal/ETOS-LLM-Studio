---
title: Tools & MCP
description: Make the AI do more than chat — connect a calculator, file ops, HTTP, external services, and automation, then keep it under control with an approval policy.
---

# Tools & MCP

An LLM by itself just talks. To make it **act on the world** — fetch weather, query a database, write a file, hit GitHub — you have to give it **tools**. This page covers ETOS's three tool categories and how the **approval policy** keeps the AI from going rogue.

## Vocabulary First

### What a Tool Is

A tool is "a function the model can call." Each tool has a name, description, and parameter schema. When the model decides it needs a tool, it emits a call request; the app executes it for real and feeds the result back to the model to continue generating.

Concrete example: you ask "What's the weather in Beijing?" The AI doesn't know — but if you've given it a **weather tool**, it:

1. Outputs "call `getWeather` with `city=Beijing`"
2. The app actually queries the weather and feeds back ("Sunny, 22°C")
3. The AI uses that to produce its reply

Without tools, all the AI can say is "I can't query real-time weather."

### Three Categories in ETOS

| Category | Where it comes from | Managed in |
| --- | --- | --- |
| **App Tools** (built-in) | Bundled in the app | Settings → Tool Center → App Tools |
| **MCP Tools** | MCP servers you connect | Settings → MCP Tool Integration |
| **Shortcut Tools** | iOS Shortcuts you expose | Settings → Shortcut Tool Integration |
| **Agent Skills** | Skill packs you import | Settings → Agent Skills |

::: tip All Independent
You can use only app tools, only MCP, or only Skills. Don't feel forced to enable all four because they exist.
:::

## Read This First

### Tool Center — The Master Dashboard

**Settings → Tool Center** opens a single list of all tools. Each row has:

| Element | Purpose |
| --- | --- |
| Master switch (atop each section) | "Expose App Tools to Model" / "Expose MCP Tools to Model" — off blocks the whole category. |
| Per-tool switch | Individual control. You might want the model to have `getWeather` but not `executeShellCommand`. |
| Approval policy | How tool calls are gated. See below. |

A search field ("Search tools") appears when you have many tools.

### Approval Policies — Three Levels

This is the **most important concept** in the tool system. It stops the AI from running risky operations without your consent.

Each tool has three policy levels:

| Policy | Behavior | When to use |
| --- | --- | --- |
| **Ask Every Time** (default) | A confirmation bubble appears in chat when the AI tries to call this tool | Unfamiliar tools, or tools with side effects (file writes, HTTP calls) |
| **Always Allow** | Auto-approve, no interruption | You trust the tool (calculator, read-only weather) |
| **Always Deny** | The model can't call it; no prompt ever appears | You want this tool unavailable (e.g. don't let the AI touch files) |

#### What the Confirmation Bubble Looks Like

When policy is "Ask Every Time", the AI's tool call request shows up as a bubble with five buttons:

| Button | Does |
| --- | --- |
| **Allow** (green ✓) | Approve this one call |
| **Deny** (red ✗) | Refuse this call; the AI is told "user denied" |
| **Supplement** (blue) | Deny but add a follow-up prompt nudging the AI in a different direction |
| **Keep Allowing** (teal) | Approve this call **and** flip this tool's policy to "Always Allow" |
| **Full Access** (purple) | Approve this call **and** flip every tool's policy to "Always Allow" |

::: warning "Full Access" Is a Nuke Button
It strips guardrails from every tool at once. **Only use it once you fully understand the behavior of every enabled tool.**
:::

### App Tools (Built-in)

ETOS ships with a starter set:

| Tool | Does |
| --- | --- |
| **File ops** | Search, chunked read, diff, partial edit, move, copy, delete — **strictly inside the app sandbox**, not your whole filesystem |
| **SQLite** | Run queries against local databases |
| **Web Card** | Turn external links into card previews inside the chat |
| **Feedback** | Auto-submit a feedback ticket to the developer |
| **Math / Text** | Basic data operations |
| **Write Memory** | Let the AI proactively store user preferences / project context to long-term memory |

Toggle each in **Settings → Tool Center → App Tools**.

### Typical Workflows

#### Scenario 1: "Find files about X"

1. Settings → Tool Center → App Tools
2. Turn on "Expose App Tools to Model"
3. Enable "File Search" and "File Read"
4. Ask in chat: "Find Markdown notes mentioning 'year-end review'"
5. AI calls the file search tool → confirmation bubble → tap Allow
6. AI reports the matches

#### Scenario 2: "Summarize this webpage"

1. Settings → MCP Tool Integration → connect a Fetch MCP server (below)
2. In chat: "Summarize https://example.com/blog/abc"
3. AI calls Fetch tool → you approve → AI summarizes

### What MCP Is and Why It Matters

**MCP** (Model Context Protocol) is an open protocol from Anthropic that defines **how an LLM client talks to an external tool server**.

Analogy:

- Before MCP: every LLM client wrote its own plugins; tools weren't portable.
- After MCP: a tool developer writes a server once, **any MCP-aware client (ETOS, Claude Desktop, Cursor, …) can use it**.

ETOS includes a full MCP client and **connects to any spec-compliant server** — both official ones (filesystem, github, postgres, puppeteer, etc.) and community projects (search, email, maps, SaaS APIs).

### Connect Your First MCP Server

**Where**: Settings → MCP Tool Integration → "+ Add MCP Server" in the top-right.

The "Add MCP Server" form:

#### Basic Info

| Field | What to put |
| --- | --- |
| Display Name | Your label, e.g. "GitHub MCP", "Web Fetch" |
| Transport | Three choices: **Streamable HTTP** (recommended), **SSE**, **HTTP**. Prefer Streamable HTTP. |

#### Endpoint

The server's actual URL. For a hypothetical fetch server, something like `https://fetch-mcp.example.com/mcp`. Check the server's own docs.

#### Authentication (optional)

If the server needs auth:

- **Bearer API Key** — paste a token, the most common case
- **OAuth 2.0** — the full flow with Token Endpoint, Client ID, Scope, etc.

#### Header Overrides (optional)

`key=value` expressions with a `{token}` placeholder that gets replaced with the Bearer API Key above:

```
Authorization=Bearer {token}
X-Org-ID=org_abc
```

#### Save → Handshake

After saving, ETOS attempts the MCP handshake automatically. On success, the server's published tool list appears in Tool Center.

### MCP Master Switch

**Settings → MCP Tool Integration → "Expose MCP Tools to Model"** is the one-tap kill switch.

> Off: no MCP tools go to the model, and any MCP calls in chat are ignored. Server connections, debugging, and per-tool config are preserved.

For when "I have MCPs configured but I don't want the AI using any tools today."

## Advanced

### Per-Session Isolation

Some sessions you might want **with no tools at all** — e.g., a roleplay session with a specific Worldbook.

The mechanism: when a session has Worldbook's **isolation mode** on, the Tool Center shows "This session has worldbook isolation enabled; this tool will not actually be active." The AI cannot call any tool in that session.

See [Memory & Worldbook](/en/modules/memory-worldbook) → Worldbook Isolation.

### MCP Server Debugging

Each MCP server's detail page shows:

- **Connection state** (connected / disconnected / error)
- **Tool list** the server publishes
- **Reconnect** button
- **Error log**

When a call fails, start here.

### Tool Source Labels

Tool Center rows show "**Source: xxx**" under MCP tools — the source is the MCP server's display name, so you know which server provides each tool.

### Tool Call Result Display

Tool results don't get jammed into the message body; they appear as **expandable cards**. Tap one to see:

- Full request parameters
- Full return value (JSON / text / image)
- Stack trace on failure
- Call duration

This is the most important entry point when debugging "why did the AI say that."

## Next

- Give the AI specialized capability bundles → [Skills & Shortcuts](/en/modules/skills-and-shortcuts)
- Long-term memory across sessions → [Memory & Worldbook](/en/modules/memory-worldbook)
- LAN debugging and feedback → [Debug & Feedback](/en/modules/debug-feedback)
