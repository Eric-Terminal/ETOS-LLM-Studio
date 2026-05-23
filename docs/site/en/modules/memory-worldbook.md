---
title: Memory & Worldbook
description: Make the AI remember who you are and what you're working on — full guide to long-term memory and the worldbook system.
---

# Memory & Worldbook

LLMs are **amnesiac** by default: each new session starts from scratch. ETOS solves this with **two complementary systems**:

| System | What it solves |
| --- | --- |
| **Memory** | Cross-session "user prefers …", "project background", "long-term facts", recalled by vector search on demand |
| **Worldbook** | When specific keywords appear in a specific session, inject background knowledge into the prompt by rule |

They sound similar but are **fundamentally different**. The concepts come first, then the configuration.

For the underlying design, see [Memory, Summary & Profile](/en/design/memory-and-profile) and [Worldbook & Tool Governance](/en/design/worldbook-and-tools).

## Concepts First

### What Memory Is

Long-lived facts — "I use Swift", "my girlfriend's name is Xiaoming", "my job is product manager" — stored in a database. Every time you send a new message, ETOS uses **vector search** to retrieve a few relevant memories and prepends them to the prompt.

**Key traits**:

- **Global** — shared across all sessions
- **Retrieved by relevance**, not blindly attached (avoids context overflow)
- **Persistent** — stays until you delete or archive

### What a Worldbook Is

Originated in SillyTavern / TavernAI roleplay circles as "Lorebook", but the use case far outgrew roleplay.

A Worldbook is a set of **entries**, each with:

- **Keywords** — trigger condition, e.g. `["Daisy", "Daisy Buchanan"]`
- **Content** — the text to inject when triggered, e.g. "Daisy Buchanan: high-society wife, beautiful and capricious…"
- **Trigger rules** — where to inject, how deep to scan, max entries

The most recent few messages in the session get scanned; entries whose keywords match get injected.

**Key traits**:

- Usually **bound to a specific session** (each roleplay session uses its own worldbook)
- **Keyword-triggered** — not blindly attached
- Injection position is **precisely controllable** (before/after system prompt, before/after latest message)

### How to Choose

| Need | Use |
| --- | --- |
| AI remembers your project across sessions | Memory |
| AI keeps your writing style across sessions | Memory |
| Your novel character "Li San" auto-injects when mentioned | Worldbook |
| RPG session where each NPC injects setting on mention | Worldbook |
| Company glossary (terms should auto-explain in context) | Worldbook |
| AI knows you asked X yesterday | Memory |

::: warning Most Common Mistake
- Stuffing **roleplay settings** into Memory → every new session gets polluted by irrelevant recalls
- Stuffing **long-term facts** into Worldbook → if the keyword doesn't appear, recall fails and the AI is amnesiac
:::

## Read This First: Memory System

### Where

```
Settings → Extended Capabilities → Memory System
```

### Configure the Embedding Model

Memory relies on an **embedding model** for vector search. The page top has an "Embedding Model" picker:

- Only **models marked for embedding** show up — you must first add an embedding model in [Providers & Models] (`text-embedding-3-large`, Cohere embed, Gemini embedding, etc.)
- Toggle the model on and set its capability to "Embedding"

You can also set a global default embedding model under **Providers & Models → Preferred Models**.

### Retrieval Settings

| Field | Effect |
| --- | --- |
| **Top K** | How many of the most-relevant memories to recall. **Default 3**. Setting it to 0 **fully disables** retrieval (memories are stored but never recalled). |
| **Active Retrieval** | Off: only user messages trigger retrieval. On: the AI can also actively request a search. |

::: tip Top K Doesn't Want to Be Big
Too high (>10):
- More tokens, costlier requests
- **Prompt cache hit rate drops to ~0** (recalls vary each turn)
- Relevance falls off, context gets polluted

**3–5 is the sweet spot.**
:::

### Two Ways to Save Memories

#### Method 1: AI Writes Them

Turn on **Settings → Tool Center → App Tools → "Write Memory" tool**.

Then in chat, when the AI judges that the user said something important ("I'm flying to Tokyo next week"), it calls the Write Memory tool to save it.

First call triggers an approval bubble; tap Allow.

#### Method 2: Manual Entry

Top-right "+ Add Memory" on the Memory Library page lets you write one yourself. Good for:

- Bulk-importing facts you already know ("My name is X", "I use macOS", "I prefer concise answers")
- Correcting a memory the AI got wrong

### Memory Management

Each memory row supports:

- **Swipe left → Delete**: permanently removed (no undo)
- **Swipe right → Archive**: kept but excluded from retrieval. Can be restored later
- **Edit**: change the raw text

The page has two sections: **Active** and **Archived**.

### Data Maintenance

The page has a "Regenerate All Embeddings" button (orange, requires confirmation). **When to use**:

- Switched embedding models (different models produce non-interchangeable vectors)
- Upgraded your primary embedding model
- Index corruption (rare)

::: danger Irreversible Operation
Clicking wipes the old SQLite vector DB and rebuilds. **Retrieval is unavailable during the rebuild.** Don't run this when you need the AI immediately.
:::

### Embedding Reconciliation

Occasionally a memory might fail to embed (network blip). The system auto-detects and offers **"Reconcile Missing Embeddings"** to retry.

## Read This First: Worldbook

### Where

```
Settings → Extended Capabilities → Worldbook
```

### Import Your First Worldbook

ETOS supports SillyTavern / NAI-format worldbooks:

| Method | Best for |
| --- | --- |
| **Import SillyTavern Worldbook (JSON/PNG)** | Local JSON files, or character card PNGs with embedded naidata |
| **Import Worldbook from URL** | A directly-accessible JSON or PNG URL, e.g. a public card repo |

Supported formats:

- **PNG naidata** — character card PNGs with embedded chara base64
- **JSON top-level array** — SillyTavern v1 standard
- **character_book format** — lorebook field nested inside a character card

The import summary shows three counts: **Imported / Skipped / Failed**.

### Editing a Worldbook

Tap a Worldbook row to open **Worldbook Detail**:

#### Basic Info

- Name / description / entry count

#### Default Settings

| Field | Effect |
| --- | --- |
| **Scan Depth** | How many recent messages to scan for keyword matches. **Typical 4–10** |
| **Max Recursion Depth** | One injection can trigger another; this caps the chain (prevents loops) |
| **Max Injected Entries** | Cap per turn. -1 = unlimited |
| **Max Injected Characters** | Character cap per turn. -1 = unlimited |
| **Fallback Position** | Where to inject when the precise position isn't reachable |

#### Entries

Each entry is a keyword-triggered injection. Per-entry actions:

- **Enable / Disable**
- **Edit** — keywords, comment, content, position
- **Delete**

### Bind a Worldbook to the Current Session

Worldbooks are **global resources** but only inject **when you explicitly bind** them.

In the Worldbook page's "Current Session" section, **"Bind Worldbook"** binds the current session to one (or more) worldbooks. Bound worldbook entries then participate in matching and injection.

### Isolation Mode (Key Feature)

When binding, you can enable **"Isolated Send"**. With isolation on:

- The session uses **only** the bound worldbooks + character setup; **no** global tools, memory, or other auto-injections
- All tools in this session become **disabled** (shown as "This session has worldbook isolation enabled; this tool will not actually be active")

Good for: **roleplay sessions**, where you don't want the AI suddenly calling a SQL query mid-scene.

## Advanced

### "Active Retrieval" for Memory

When on, the AI **decides whether to search**. Mechanism: the model sees "you can call `search_memory`" in its tool list and chooses to invoke it when relevant.

Use when:

- Long conversations where some topics need historical recall
- The AI suspects current input relates to a past fact

Don't use when:

- You don't want the AI to spend reasoning budget on recall
- Most sessions are fresh topics where recall doesn't help

### How Entry "Position" Works

Each worldbook entry can target precise positions:

- Before/after the system prompt
- Before/after the latest user message
- Before the assistant's latest reply
- Custom depth (N messages back)

Example: "Character background" suits "after system prompt"; "scene description" suits "before latest user message".

### Worldbook Export

Each worldbook can **Export** back to JSON — interoperable with SillyTavern.

Use cases:

- Edit in ETOS, use elsewhere
- Back up cards you've authored

### Memory vs Session Summary vs Profile

ETOS also has a **session summary** layer (details in [Memory, Summary & Profile](/en/design/memory-and-profile)). Quickly:

- **Memory** — facts written by you / the AI
- **Summary** — auto-generated overview per session
- **Profile** — auto-distilled "user characteristics" across all sessions and memories

Most users **only need to think about Memory**. Summary and profile run in the background.

## Next

- Get proactive briefings → [Daily Pulse](/en/modules/daily-pulse)
- See the full prompt assembly order → [Prompt & Context Assembly](/en/design/prompt-assembly)
- Memory / summary / profile design → [Memory, Summary & Profile](/en/design/memory-and-profile)
