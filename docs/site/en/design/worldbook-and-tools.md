---
title: Worldbook & Tool Governance
description: Worldbook decides "what extra rules to inject." Tool Center decides "what tools this session can actually call." They overlap — this page explains how.
---

# Worldbook & Tool Governance

This page covers two things that **easily get conflated**:

- How **Worldbook** decides "what extra rules or settings to inject"
- How **Tool Center** decides "whether this session can actually call a given tool"

They look like independent feature lines, but **interact through "isolated send"**. Understanding that link is key to using ETOS well.

::: tip Read First
Get familiar with [Memory & Worldbook](/en/modules/memory-worldbook) and [Tools & MCP](/en/modules/tools-and-mcp) usage first.
:::

## I. Worldbook Isn't a Notes Field

Worldbook in ETOS **isn't "drop a lore blob there"** — it's a **triggerable, sortable, rate-limited injection engine**.

The basic unit is an **entry**. Each entry defines at minimum:

- Primary keywords
- Secondary keywords
- Secondary key logic
- Injection position
- Role
- Scan depth
- Depth position
- Probability, delay, sticky, cooldown
- Recursive allowance

It's a **rules system**, not casual notes.

### How Triggering Works

Worldbook evaluation reads the **current session message buffer** and judges each entry. Basic logic:

1. Pull **bound worldbook set**
2. Apply **book and entry settings** to determine scan depth
3. Match **primary and secondary keywords**
4. Apply **probability, delay, sticky, cooldown, recursion** runtime effects
5. **Group rules and budget rules** trim excess entries

::: warning Triggered ≠ Always Injected
Worldbook is **budget-constrained** — even if all entries match, the limits cap how many get injected.
:::

### Why Secondary Key Logic Matters

ETOS supports not just primary keys but **secondary keys** and **selective logic**.

This lets an entry express complex conditions:

- Trigger only if **any one** secondary key hits
- Trigger only if **all** keys hit
- Don't trigger if certain keys appear

That makes worldbook suitable for **real context constraints**, not just text replacement.

### Recursion / Delay / Sticky / Cooldown

Sound complex, but all solve **"worldbook is too mechanical"**:

| Mechanism | Solves |
| --- | --- |
| **Recursion** | An entry can be **retriggered by already-injected content** |
| **Delay** | Not injected on first hit — appears **after N turns** |
| **Sticky** | Once triggered, **stays active for next few turns** |
| **Cooldown** | After triggering, **suppress for N turns** |

Without these, large worldbooks **degenerate into prompt spam**.

### Position Matters

Worldbook entries can land at multiple positions:

| Position | Effect |
| --- | --- |
| Before system | Top of system prompt |
| After system | Bottom of system prompt |
| AN top | Top of context |
| AN bottom | Bottom of context |
| At depth | Inserted into chat history at specific depth |
| Before message | Just before the latest message |
| After message | Just after the latest message |
| Outlet | Middle outlet |

So worldbook **isn't just "attach a paragraph"** — it can target precisely **which layer of message structure to affect**.

### Why Budget Control Is Necessary

After worldbook evaluation, ETOS does **budget trimming**, at minimum:

- **Max injected entries**
- **Max injected characters**

Without this, large worldbooks easily **eat the entire context window**.

## II. What Worldbook Isolation Means

This is one of ETOS's **most distinctive designs**.

When a session has a worldbook bound and **"isolate memory and tools on binding"** enabled, the session enters a **purer context mode**.

### Sent During Isolation

- Global prompt
- Topic prompt
- Enhancement prompt
- Worldbook content

### Not Sent During Isolation

- Long-term memory
- Cross-session summary
- User profile
- MCP tools
- Shortcut tools
- Other external tool context

### Why

Because **roleplay, rules-simulation, setting-driven sessions** fear most being "**contaminated**" by external tools and long-term user preferences.

E.g., you're in a cyberpunk RPG session — you don't want the model suddenly going "based on your profile, you prefer concise answers." That isn't the NPC talking.

## III. What Tool Center Actually Governs

Many AI apps build tool management as a **shallow on/off list**.

ETOS's Tool Center is closer to a **capability governance layer**. It cares not just "did the user enable it," but:

- Is it **actually available in this session**
- Does it need **approval**
- Is it **blocked by worldbook isolation**
- Is the server **selected for chat**
- Is the **individual tool disabled**
- Is the approval policy **"Always Deny"**

### "Configured Enabled" ≠ "Available in This Session"

Tool Center makes a **key distinction**:

| State | Meaning |
| --- | --- |
| Configured enabled | User flipped the toggle in settings |
| Available this session | The tool **really gets sent to the model** in this conversation |

The two **frequently disagree** — usually **not a bug**, it's a deliberate **explanation layer**.

#### Typical Disagreement Cases

| Scenario | Behavior |
| --- | --- |
| Memory write on, but session has **worldbook isolation** | Configured on, session unavailable |
| MCP server online, but **not selected for chat** | Configured on, session unavailable |
| Tool on, but approval policy is **Always Deny** | Configured on, model never sees it |

Tool Center **explicitly shows the reason** — e.g., "This session has worldbook isolation enabled; this tool will not actually be active."

### Built-in Tool Governance Dependencies

ETOS treats some capabilities as **built-in tools**, e.g.:

- `save_memory` (write memory)
- `search_memory` (search memory)
- Widget card capability
- `ask_user_input` (ask user for input)

**Memory write and memory search** depend not just on the tool toggle but on **memory system config**:

- Memory master switch
- Write allowed
- Active retrieval enabled
- **`Top K > 0`**
- **Session not under worldbook isolation**

Any failed condition makes the tool effectively unavailable.

### MCP Governance Logic

MCP **doesn't auto-enter chat just because the server is configured**. Several gates:

1. Is the **server selected for chat**
2. Did the server's metadata **actually publish any tools**
3. Is the **individual tool enabled**
4. Is the tool's approval policy **not "Always Deny"**

When Daily Pulse reads MCPs, it only uses "**summary of currently available capabilities**" as callable — **it doesn't pretend to have fetched live external data**. This is a hard rule repeatedly emphasized in Daily Pulse design.

### Why Shortcut Direct vs Bridge

ETOS provides two **priority modes** for Shortcut tools:

- **Direct first**
- **Bridge first**

**Not a visual option** — an **execution strategy**:

- Call the target Shortcut directly
- Or proxy through the bridge Shortcut first, return result

This lets Shortcuts both **stay lightweight** (direct) and **handle complex parameters / callback flows** (bridge).

### Why Tool Description Is Also Governance

In ETOS, **tool description isn't pure UI text** — it's the **capability declaration the model sees**.

So Shortcut tools support:

- **Custom description**
- **Let the model regenerate description**

Goal isn't prose polish — it's bringing "**how the model understands this tool**" into the tunable parameters. A clearly-described tool gets called more accurately; a vague one gets misused or ignored.

## How to Put It All Together

| System | Solves |
| --- | --- |
| Worldbook | What **rules and setup** to give the model |
| Tool Center | What **capabilities** to give the model, and whether those capabilities are **really available** in this session |

The two stacked give ETOS an important trait:

> **It isn't just about making the model stronger — it makes context and capabilities both explainable, governable, and isolatable.**

That's why Settings is long — it's the **governance console for an entire AI system**.

## Next

- See the full context assembly order → [Prompt & Context Assembly](/en/design/prompt-assembly)
- See how Daily Pulse uses this governance result → [Daily Pulse Internals](/en/design/daily-pulse)
- See the three-layer memory details → [Memory, Summary & Profile](/en/design/memory-and-profile)
