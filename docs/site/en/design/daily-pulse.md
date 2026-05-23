---
title: Daily Pulse Internals
description: Daily Pulse isn't a feed or a second chat. It's a proactive curator built on eight local signals. This page covers what it depends on, what it produces, and why delivery isn't guaranteed.
---

# Daily Pulse Internals

This page explains why Daily Pulse can proactively surface "what's worth looking at today" and **which real signals it depends on**.

Positioning: **not a news feed, not another chat tab — a proactive curation layer**.

::: tip Read First
We recommend trying [Daily Pulse](/en/modules/daily-pulse) first (generate manually a few times, give some feedback). Concepts like "feedback profile", "open tasks", "tomorrow curation" stay abstract without hands-on.
:::

## The Real Problem Daily Pulse Solves

Most AI products assume the user knows what to ask. The reality often is:

- The user just opened the app and **hasn't formed a question**
- The user knows they're busy but **doesn't know which thing to push next**
- The user's long-term interests, tool capabilities, and recent chats are **enough to suggest a few high-value directions**

Daily Pulse **front-loads** that step.

## It's Not a "Cloud Recommendation System"

Daily Pulse's signal sources are **local context and locally-already-fetched results**, not a server-side profile.

It doesn't rely on a unified account profile for cross-user recommendation. It curates around this device's actual usage trail. This means:

- It's closer to a **personal curator**, not a public feed
- Its quality depends heavily on your **real usage and feedback discipline**
- **It can't know external facts out of nothing** — only if you gave context, or recently fetched MCP / Shortcut output

## The Eight Input Sources

A `DailyPulseGenerationInput` is built at generation time, with eight categories.

### 1. User-Authored Focus

If you wrote "what to focus on today" in Daily Pulse, it becomes a **top-priority** personal signal.

### 2. "What I Want Tomorrow" Curation

**Not an instantly-effective note** — it's curation aimed at the next batch.

Good for:

- Direction to keep advancing tomorrow
- Topics to dial down
- Card types to dial up

### 3. Recent Chat Excerpts

Daily Pulse doesn't pour all history in. It takes truncated slices of recent sessions.

Current defaults:

- Up to **4 sessions**
- Up to **6 user/assistant messages** per session

The goal isn't full recall — it's understanding **what you've been busy with**.

### 4. Long-Term Memory

It reads un-archived long-term memories, capped.

Current default: at most **8 entries**, length-compressed.

This lets Daily Pulse remember:

- The content types you favor over time
- The projects you keep pushing
- Topics you consistently care about

### 5. Recent Request Log Summary

The last **7 days** of activity get squeezed into a short summary:

- Total request count
- Frequently-used providers
- Frequently-used models

**Not a tech stats report for the model** — just letting it know what you've been leaning on.

### 6. Open Pulse Tasks

A card you convert into a task **doesn't stay a one-off recommendation** — it participates in later generations.

Design intent:

- Daily Pulse covers discovery **and** follow-through
- But **doesn't robotically repeat the old card title** — it leans toward "help push one step forward"

### 7. Feedback Preference Profile

Historical feedback is shaped into three prompts:

- Topics you're **more likely to want**
- Topics to **avoid**
- Topics that **already showed up in recent days**

Sources: manual likes / downvotes / hides, plus "**save as conversation**" as a strong positive signal.

### 8. External Capabilities and Results

**The most often-misunderstood layer**. Daily Pulse distinguishes three things:

| Type | Meaning |
| --- | --- |
| **Available capabilities** | Which MCP servers are selected for chat, which Shortcuts can be called |
| **Recently-fetched external result snapshots** | Most recent Shortcut result, most recent MCP output |
| **Announcements & trend signals** | App announcements, trend-style signals |

::: warning A Hard Constraint
Tool capability descriptions only mean "**can be called**" — they **do not mean live data has been fetched**.

Only "**recently-fetched external result snapshots**" represent external content the user actually has.
:::

## Defaults and Retention

Concrete defaults in the current implementation:

| Item | Default |
| --- | --- |
| Auto-generate | On |
| MCP context | On |
| Shortcut context | On |
| Recent external result snapshots | Off |
| Trend / announcement signals | On |
| Final card count | 3 |
| Model candidate count | 6 |
| Run retention | 14 days |
| Feedback history retention | 120 entries |
| External signal retention | 40 entries |
| Task retention | 80 entries |

Also note:

- Persistence **keeps multiple recent days**
- The UI **shows only "today"** by default

Historical batches **feed feedback and preference accumulation**, not a timeline feed.

## Model Selection Priority

Daily Pulse tries the dedicated model first:

1. The user's explicitly-set **Daily Pulse Model**
2. The current chat model, **if** it supports chat
3. The first chat-capable active model

This lets you tune Daily Pulse independently without it silently breaking when no dedicated model is set.

## Prompt Strategy

The Daily Pulse system prompt **doesn't free-roam**. It spells out the job and boundaries.

Core rules:

- Curate based on recent chats, long-term memory, usage trail, feedback, external capabilities, and user-authored input
- **Prefer pushing open tasks forward**, don't restate old titles verbatim
- Cards must be **specific, continuable, and savable as a new session**
- **Don't fabricate user history**, don't invent external facts
- With MCP / Shortcut capabilities, prefer cards that can be **immediately advanced**
- **Tool capability ≠ live data fetched**
- Output must have **diversity** — three cards shouldn't all orbit the same thing
- Topics the user has clearly disliked → minimize

## Output Schema

The model must return **JSON only**, no Markdown code fences.

Fixed structure:

```json
{
  "headline": "single-sentence top headline",
  "cards": [
    {
      "title": "card title",
      "why": "why this is for the user",
      "summary": "one or two sentences",
      "details_markdown": "detailed Markdown that can be saved as the first chat message",
      "suggested_prompt": "if continued, what to send"
    }
  ]
}
```

Five fields solve five problems:

| Field | Role |
| --- | --- |
| `title` | What the user sees first in the list |
| `why` | Why you specifically, not random |
| `summary` | Decide at a glance if it's worth opening |
| `details_markdown` | First-message content if saved as a session |
| `suggested_prompt` | Quick follow-up without re-thinking the question |

## Model Proposes, Client Filters

Daily Pulse **doesn't trust the model's raw output** verbatim. Actual flow:

1. Ask the model for **6 candidate cards**
2. Client does **normalization, length trimming, fallback**
3. Client **scores by preference profile** and filters down to **3**

## Local Filtering Rules (Explainable Scoring)

| Rule | Delta |
| --- | --- |
| Near user's current focus | `+4` |
| Hit past positive feedback topics | `+3` |
| Hit topics shown recently | `-2` |
| Hit past negative feedback topics | `-6` |
| Details are substantial | `+1` |

Then three more steps:

- Drop cards **too similar to negative-feedback topics**
- Drop cards **too similar to each other**
- Avoid all three falling into one category

That's why Daily Pulse looks like "model-generated" but **carries a clear product-curation flavor**.

## Feedback Loop

A card can receive four classic feedback types:

- Liked
- Downvoted
- Hidden
- Saved as conversation

These **don't train a remote recommender**. They directly become **prompt input for the next local curation**.

Daily Pulse's "learning" is more **next-round prompt hinting**, not an opaque weight update.

## Why "Save as Conversation"

A **key design**.

Saving a card creates:

- A new session named after the card title
- The card's `details_markdown` as the **first assistant message**
- A record of this action as **strong positive feedback**

So Daily Pulse **isn't a terminal — it's a chat-entry generator**.

## Why "Convert to Task"

Some cards don't need chat right now; they need follow-up.

Tasks preserve:

- Title
- Summary
- Suggested prompt
- Completion state

Later generations factor open tasks into curation.

## Why Delivery Isn't Guaranteed

Daily Pulse alerts and delivery are **local capabilities**, not server push.

Current defaults:

- Morning reminder **off** by default
- Default reminder time **08:30**
- iPhone **prepares today's batch ahead of time when possible**
- If reminder time hits before prep finishes, send a **"ready" notification**
- Apple Watch leans on **foreground-resume** to start prep

The whole design is **best-effort**:

- Respect iOS scheduling boundaries
- Don't pretend to be an always-on cloud cron

## How to Accurately Think About It

The most accurate framing **isn't "daily recommendations"** but:

> **A proactive curator driven by recent chats, long-term memory, usage trail, external capabilities, feedback history, and open tasks.**

Its value isn't "think for you" — it's **reorganize context you've already accumulated but haven't structured into a few actionable entry points**.

## Next

- See how memory / summary / profile each work → [Memory, Summary & Profile](/en/design/memory-and-profile)
- See worldbook + tool governance details → [Worldbook & Tool Governance](/en/design/worldbook-and-tools)
