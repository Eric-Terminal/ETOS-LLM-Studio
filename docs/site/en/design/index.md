---
title: Design Philosophy
description: ETOS LLM Studio isn't "wrap an API and display text." It's a native AI workstation. This page explains how it's designed and why.
---

# Design Philosophy

This set of documents is the **product design spec** for ETOS LLM Studio, not marketing material. The goal:

- Help newcomers understand how the product works **without reading Swift code**
- Help current users know which behavior is **deliberate design** vs **just a default**
- Help external contributors understand the **module boundaries** between Daily Pulse, Memory, Worldbook, MCP, and Shortcuts

::: tip Before Reading This Set
We recommend you **use ETOS for a few days first** — configure a provider, send a few rounds of chat, install at least one Skill or MCP. Design docs are abstract on their own; hands-on first makes everything easier.

Not installed yet? [Install & First Launch](/en/guide/installation).
:::

## ETOS Is Not a Chat Wrapper

Most LLM clients position themselves as "wrap a model API in a usable app." ETOS targets something different: **fit the following into a single native client**.

| Subsystem | Responsibility |
| --- | --- |
| **Chat** | Multi-provider, multi-model, multimodal, fine-grained request tuning |
| **Context** | Global prompt, topic prompt, enhancement prompt, long-term memory, cross-session summary, user profile, worldbook |
| **Proactive** | Daily Pulse generates "what to look at today" before you ask |
| **Tools** | Built-in tools, MCP, Shortcuts, Skills, sandbox file tools — unified under one governance |
| **Two-device experience** | iPhone for full configuration + management; Apple Watch for quick access + alerts + lightweight follow-up |

Complexity is much higher than "API + text display." That's why explicit design principles matter — otherwise the system tears itself apart past a certain point.

## Four Design Principles

### 1. Explainable

ETOS deliberately avoids "**the model suddenly got smart, but you have no idea what it just saw**."

Context is split into a clear hierarchy:

| Layer | Responsibility |
| --- | --- |
| **Global prompt** | Long-term identity and overall rules ("you are AI X") |
| **Topic prompt** | Current session's subject constraints |
| **Enhancement prompt** | Per-turn auto-added instruction |
| **Memory / Session summary / User profile** | Long-term and cross-session background |
| **Worldbook** | Rule-based, conditionally-triggered targeted injection |

Each layer **can be toggled independently** — you can run with everything on, or strip down to a bare model, instead of accepting a black box.

For the full assembly order, see [Prompt & Context Assembly](/en/design/prompt-assembly).

### 2. Proactive but Low-Interruption

**Daily Pulse** isn't "replace chat." It solves a real problem: **a lot of people open the app each day not knowing what to ask**.

Approach:

- **One card stack per day**, not an infinite feed
- **Feedback-driven** (like / downvote / hide / save), not forced recommendations
- **Local persistence + local reminders**, not cloud account push
- **Best-effort morning delivery**, not a promised cloud cron job

Details in [Daily Pulse Internals](/en/design/daily-pulse).

### 3. Tools Are Governed, Not Maxed Out

ETOS doesn't market "number of tools." It treats "**what tools are actually exposed in this session**" as the more important question.

Tool Center has at least two state layers:

- **Configured to be enabled**
- **Actually available in this session**

The two often differ. Factors:

| Factor | Effect |
| --- | --- |
| Approval policy | "Always Deny" blocks even configured-on tools |
| Worldbook isolation | The whole session disables tools |
| MCP server selected for chat | Unselected servers don't contribute tools |
| Per-tool disable | Same |

Details in [Worldbook & Tool Governance](/en/design/worldbook-and-tools).

### 4. Two-Device Division of Labor, Not Mirror

iPhone and Apple Watch are **not the same UI shrunk down**.

| Device | Job |
| --- | --- |
| iPhone | Provider config, tool governance, worldbook editing, memory management, import/export, debug/feedback |
| Apple Watch | Receive alerts, quick session start, follow up on Daily Pulse, voice or short text input |

That's why ETOS pushes complex policy down to the **shared layer** (`Shared/Shared/`) rather than hard-coding it into a specific screen — the shared layer lets each device take what it needs.

## Data-Flow Overview

```text
User input  /  Daily Pulse cards  /  External tool results
              │
              ▼
        ChatService request orchestration
              │
    ┌─────────┼─────────┐
    │         │         │
    ▼         ▼         ▼
 Prompt    Memory    Worldbook
              │
              ▼
        Tool exposure & approval
              │
              ▼
        Send to selected model
              │
              ▼
      Response, summary, profile, feedback writeback
```

Every model-bound request goes through this pipeline.

## Where to Start

| Your question | Read |
| --- | --- |
| What goes into the prompt before a message is sent? | [Prompt & Context Assembly](/en/design/prompt-assembly) |
| Why is Daily Pulse "proactive"? What signals feed it? | [Daily Pulse Internals](/en/design/daily-pulse) |
| What do memory, session summary, and user profile each do? | [Memory, Summary & Profile](/en/design/memory-and-profile) |
| Why does a worldbook affect tool availability? | [Worldbook & Tool Governance](/en/design/worldbook-and-tools) |

## One Overall Take

If you treat ETOS purely as a chat wrapper, **many entry points look scattered**.

If you treat it as a **native AI workstation**, things click:

| Module | Role |
| --- | --- |
| Chat tab | Execution |
| Settings tab | Governance |
| Daily Pulse | Proactive discovery |
| Memory + Worldbook | Long-term context |
| Tool Center | Capability exposure + risk control |

Settings is long because it's the **governance console for an entire AI system** — not "too many features piled up," but "governance itself needs this many panels."
