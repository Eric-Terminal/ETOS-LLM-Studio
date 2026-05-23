---
title: Interface Tour
description: A map of every sub-screen tucked away inside Settings — where each entry lives, what it opens, and which problem it solves.
---

# Interface Tour

ETOS LLM Studio only has two main tabs: **Chat** and **Settings**. That looks sparse, but Settings is the cockpit for the whole app — 20+ sub-screens. This page is the full map so you never get lost.

## The Chat Tab

Where you spend most of your time. Physical layout:

```
Top bar:    [Menu]   "New Conversation" title   [Model]   [More]
↓
Center:     conversation surface (message bubbles)
↓
Input area: [+]  [Text field]  [Tool toggles]  [Send]
```

**What you do here** (most-used first):

- Send text / images / voice / files
- Switch the current session's model (top-right)
- Long-press a message → copy, edit, delete, export, branch
- Top-left menu → session list (search / folders / new)
- Tool toggles near the input field — **per-turn only**: web search, MCP tools, Skills, Shortcuts

::: tip Long-press Does Almost Everything
ETOS packs per-message actions into the long-press menu: copy, quote, edit, delete, token info, thinking detail, export, branch, … When you can't find an action, long-press first.
:::

## The Settings Tab

A grouped list. The order below is the **actual on-screen order**:

### Section 1 · Current Model

| Entry | Does |
| --- | --- |
| **Model** | Picks the default model used by new sessions. Lists every model with its switch turned on. |
| **Start New Conversation** | Creates a fresh session and bounces back to the Chat tab. |

::: warning "No models available"
If this section reads "No models available. Please enable one under Providers & Models.", you added a provider but didn't toggle on a model row.
:::

### Section 2 · Conversation

| Entry | Does | Deep dive |
| --- | --- | --- |
| **Session History** | Cross-session search, folder grouping, batch move/delete | [Chat & Models](/en/modules/chat-and-models) |
| **Providers & Models** | Add/edit providers, configure API keys, fetch model list, connectivity test | [Add Your First Provider](/en/guide/first-provider) |
| **Preferences** | Global system prompt, temperature/top_p, streaming, max history, inject system time | [Chat & Models](/en/modules/chat-and-models) advanced |
| **Text-to-Speech (TTS)** | Pick the default TTS model, read-aloud speed | [Chat & Models](/en/modules/chat-and-models) |

### Section 3 · Extended Capabilities

The longest group. All "extras" live here:

| Entry | Does | Deep dive |
| --- | --- | --- |
| **Tool Center** | All local tools the model can call (calculator, files, HTTP, …) + approval policy | [Tools & MCP](/en/modules/tools-and-mcp) |
| **Daily Pulse** | Scheduled "what's worth reading today" cards | [Daily Pulse](/en/modules/daily-pulse) |
| **Usage Analytics** | Token usage / spend by provider / model / date | [Chat & Models](/en/modules/chat-and-models) |
| **Memory System** | Cross-session long-term memory: preferences, project context | [Memory & Worldbook](/en/modules/memory-worldbook) |
| **MCP Tool Integration** | Connect Model Context Protocol servers (GitHub, FS, search, …) | [Tools & MCP](/en/modules/tools-and-mcp) |
| **Agent Skills** | Import local Skill packs giving the model specialized abilities | [Skills & Shortcuts](/en/modules/skills-and-shortcuts) |
| **Shortcut Tool Integration** | Expose iOS Shortcuts as model-callable tools | [Skills & Shortcuts](/en/modules/skills-and-shortcuts) |
| **Image Generation** | Configure image-gen models like DALL·E / Imagen | [Chat & Models](/en/modules/chat-and-models) |
| **Worldbook** | Keyword-triggered "patch" knowledge injection | [Memory & Worldbook](/en/modules/memory-worldbook) |
| **Speech Input** | Configure STT (speech-to-text), or send voice as native audio | [Chat & Models](/en/modules/chat-and-models) |
| **Extended Features** | Experimental / debug toggles | [Debug & Feedback](/en/modules/debug-feedback) |

::: info All Independent
Every item is **independently toggleable**. Want Daily Pulse but not MCP or Worldbook? Fine. The list is long but you only turn on what you use.
:::

### Section 4 · Display & Experience

| Entry | Does | Deep dive |
| --- | --- | --- |
| **Backgrounds & Visuals** | Chat background image, blur, opacity, auto-rotate, Liquid Glass, advanced Markdown renderer, auto-preview thinking | [Hidden Gems](/en/tips/hidden-gems) |
| **Sync & Backup** | iPhone ↔ Watch sync, ETOS bundle import/export, third-party import (Cherry Studio / RikkaHub / Kelivo / ChatGPT) | [Sync & Backup](/en/modules/sync-backup) |

### Section 5 · About

| Entry | Does |
| --- | --- |
| **About ETOS LLM Studio** | Version, license, credits, privacy policy |

### Section 6 · System Announcements (when present)

Shown only if the developer has pushed announcements (important updates, API compatibility notes, …).

## The Watch App

The Watch app is a slimmed-down companion. **No full configuration UI**; its main jobs:

- **Start a conversation** with already-configured providers and models
- **Browse synced sessions**
- **Receive Daily Pulse pushes** and read them in notifications
- **Speech input** — hold the crown or raise to wake and speak directly

What's **not** on the Watch: provider config, Worldbook editing, MCP management, Skills management. Configure all of these on the iPhone, then sync over.

## When You Can't Find Something

Use this fallback order:

1. **Per-message action?** → Long-press a message in chat
2. **Per-session action?** → Top-left menu → session list
3. **Configuration?** → Settings → Extended Capabilities (highest hit rate)
4. **Look-and-feel?** → Settings → Display & Experience
5. **Cross-device / import / export?** → Settings → Display & Experience → Sync & Backup
6. **Still nothing?** → Use the doc-site search

## Next

With the layout in your head, dive into whichever module matters:

- [Chat & Models](/en/modules/chat-and-models)
- [Tools & MCP](/en/modules/tools-and-mcp)
- [Skills & Shortcuts](/en/modules/skills-and-shortcuts)
- [Memory & Worldbook](/en/modules/memory-worldbook)
- [Daily Pulse](/en/modules/daily-pulse)
- [Sync & Backup](/en/modules/sync-backup)
- [Debug & Feedback](/en/modules/debug-feedback)
