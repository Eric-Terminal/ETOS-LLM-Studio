---
title: Memory, Summary & Profile
description: ETOS's "long-term context" is actually three layers — long-term memory, session summary, user profile. This page explains each one's responsibility and boundary.
---

# Memory, Summary & Profile

First-time users of ETOS's "memory" feature often conflate every long-term context into one thing.

**There are at least three layers**:

| Layer | Job |
| --- | --- |
| **Long-Term Memory** | Discrete, searchable facts or preferences |
| **Session Summary** | Compressed record for cross-session continuity |
| **User Profile** | More stable long-term preferences and background |

They're **three different responsibilities, not three names for one thing**. Treat them as "AI memory" and the feature count overwhelms you; understand the responsibility separation and you can decide exactly which layer each fact belongs in.

::: tip Read First
Familiarize yourself with [Memory & Worldbook](/en/modules/memory-worldbook) and the position of each layer in [Prompt & Context Assembly](/en/design/prompt-assembly) first.
:::

## I. Long-Term Memory: Discrete, Searchable, Editable

Good for:

- **Stable preferences**
- **Long-term project background**
- Explicit "please remember this" requests

Bad for:

- Parameters needed only for today's conversation
- A single file's transient contents
- One-off arrangements
- Sensitive privacy

### The `save_memory` Tool's Boundary Rules

ETOS's built-in `save_memory` tool **explicitly writes its boundaries** in the description:

- Only write something that will be **useful across many future conversations**
- Stable preferences, long-term identity, long-term collaboration context — write
- Explicit "remember this" requests — write
- **One-off details, short-term tasks, sensitive info, third-party privacy — by default don't write**

Not over-conservative — this **prevents the memory library from being polluted by short-term noise**.

### Storage Model

Long-term memory **isn't just a plain text list**. At least two internal forms:

| Form | Use |
| --- | --- |
| **Raw memory** | The actual user-intended content |
| **Vector index** | Chunked + embedded for retrieval |

Lifecycle:

```text
Write raw text
  → Chunk
  → Generate embeddings
  → Build vector index
  → Retrieve before reply when needed
```

::: warning Works Without an Embedding Model
If no embedding model is configured, **raw memories still save**, but **vector retrieval can't run** — only manual "no Top K filter, attach all" works (see [Prompt & Context Assembly](/en/design/prompt-assembly)).
:::

### Two Retrieval Modes

#### Vector Retrieval `vector`

Best for natural-language questions:

- "What writing style have I preferred?"
- "What long-term projects am I working on?"

#### Keyword Retrieval `keyword`

Best for names, terms, phrases:

- A project code name
- A fixed terminology
- A person or device name

ETOS **explicitly exposes** the `mode` parameter on `search_memory` so the model can pick precisely, instead of doing a stealth hybrid retrieval.

### Archive ≠ Delete

A long-term memory can be **archived**:

- No longer participates in retrieval
- But **raw text and vectors stay**

Good for "this used to matter but shouldn't keep affecting replies" — completed projects, abandoned directions, etc.

## II. Session Summary: Cross-Session Continuity Compression

**Session summary isn't a replacement for long-term memory.** It solves a different question:

> "**Where did this conversation thread leave off?**"

Compared to long-term memory, it's more like **stage-level compression**.

### Trigger Strategy

ETOS judges whether to generate session summaries **asynchronously** after a chat. Default thresholds:

| Item | Default |
| --- | --- |
| Cross-session memory | On |
| Minimum user turns to trigger generation | **6** |
| Minimum interval between summaries on the same session | **120 minutes** |
| Number of recent summaries injected into later turns | **5** |

It uses a **dedicated detached completion** to generate in the background — **doesn't pollute current chat history**.

### Summary Prompt Goals

A session summary is **not a meeting minutes** — it's a **cross-conversation reusable short summary**.

Requirements:

- **60–140 characters** of output
- Only keep key topics, user intent, explicit conclusions
- No bullet listing of details
- No disclaimers

Maintains context continuity without dragging back all historical noise.

## III. User Profile: A More Stable Long-Term Layer

User profile is a **higher abstraction** than session summary.

**Not per-session — describes the whole person long-term**.

Required emphasis:

- **Stable preferences**
- **Work background**
- **Long-term focus**

Actively avoid:

- One-off details
- Short-term noise

### Default Update Policy

Default: profile auto-updates **once per day**, manually editable / overridable / clearable in settings.

### Why Profile Isn't Authoritative

When sent to the model, ETOS **explicitly labels** it as:

- A **profile asynchronously distilled from historical conversations**
- **Should not be treated as a new user instruction**

In other words — **profile is a reference layer, not the top rule layer**. The model should treat it as "the user is likely like this" rather than "the user is commanding me to do this."

## How the Three Layers Cooperate

### Quick Reference

| Layer | Role | Good for |
| --- | --- | --- |
| **Long-Term Memory** | Discrete fact retrieval | Stable preferences, long-term background, explicit "remember" requests |
| **Session Summary** | Cross-session continuity | What this thread did recently, what was concluded |
| **User Profile** | Long-term abstract portrait | Stable style, long-term focus, work background |

### Typical Examples

| Want the AI to remember | Belongs in |
| --- | --- |
| "Reply in Chinese by default" | Long-Term Memory |
| "We've been rewriting the docs site to the Teek theme" | Session Summary (auto) |
| "User values explainability, likes the design rationale spelled out" | User Profile (auto + manual edit) |

## Why Not Stuff Everything Into Long-Term Memory

Two bad outcomes:

- Memory library **flooded with short-term tasks**
- Model **can't distinguish "long-term fact" from "recent progress"**

The three-layer split lets ETOS do:

- **Long-term memory** for **fact** retrieval
- **Session summary** for **thread** continuity
- **User profile** for **preference** distillation

Not feature stacking — **a prerequisite for the AI to be able to explain "why I said what I said."**

## Next

- See worldbook + tool governance details → [Worldbook & Tool Governance](/en/design/worldbook-and-tools)
- See the full context assembly order → [Prompt & Context Assembly](/en/design/prompt-assembly)
