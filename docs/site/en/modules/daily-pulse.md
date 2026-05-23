---
title: Daily Pulse
description: Have the app proactively generate a "what's worth looking at today" card stack every morning — driven by your real chat, memory, feedback, and external context.
---

# Daily Pulse

Most LLM clients wait for you to ask. **Daily Pulse** flips it around: every morning, ETOS auto-generates a stack of "things worth your attention today" and shows them to you proactively.

The signal sources **aren't guesses** — they come from your recent chats, memory, feedback history, "tomorrow curation" inputs, and (optionally) external MCP / Shortcut results. This page covers configuration. For the actual code-level signal sources, see [Daily Pulse Internals](/en/design/daily-pulse).

## When It's Useful

| Scenario | How it helps |
| --- | --- |
| You wake up unsure what to focus on | Cards literally list "N things you might want to follow up on" |
| You're juggling several projects | Aggregates unfinished items scattered across sessions |
| You consume many information sources | MCP / Shortcut tools fan-in news, mail, calendar |
| You want the AI to "learn you" | Like / down-vote / hide / save feedback gradually shapes preferences |

If you just chat occasionally, you can skip Daily Pulse entirely.

## Read This First

### Where

```
Settings → Extended Capabilities → Daily Pulse
```

### First-time Setup: Four Steps

#### 1. Pick a Model

Daily Pulse generates with a **dedicated model**:

```
Settings → Providers & Models → Preferred Models → Daily Pulse Model
```

Choose something **cost-effective** — runs once a day, but produces moderately long output (around 3 cards). Recommendations:

| Model | Why |
| --- | --- |
| GPT-4o-mini | Cheap, fast, summarizes well |
| Claude 3.5 Haiku | Same |
| Gemini 2.5 Flash | Same |
| Your flagship | If you want premium summaries |

#### 2. Enable Auto Generation

Top of the page:

| Toggle | Effect |
| --- | --- |
| **Auto-generate on First Daily Open** | On first daily app launch, generate if today's run is missing |
| **Morning Reminder** | Push notification when today's run is ready |
| **Reminder Time** | Default 8:00 |

#### 3. Run It Manually Once

To see results immediately, tap **"Generate Now"** (✨ icon).

> Generation will use your recent chats, memory system, request logs, feedback history, tomorrow curation, and focus topics — optionally combined with external context — to produce about 3 cards.

First run typically takes 10–30 seconds, slower the slower your model.

#### 4. Look at Cards + Give Feedback

After generation a "Today's Cards" section appears. Each card has four feedback buttons:

| Button | Meaning |
| --- | --- |
| ❤️ **Liked** | Useful — give me more like this |
| 👎 **Downvoted** | Don't want this — generate less |
| 🙈 **Hidden** | Don't show this one again |
| 🔖 **Save as Conversation** | Convert this card into a full session and continue chatting |

Feedback accumulates as **long-term preference signals** that shape later generations. **Genuine feedback beats model-hopping for improving quality.**

### Focus + Tomorrow Curation

Two text inputs in the middle of the page where you **tell Daily Pulse directly what you want**:

#### Current Focus

> e.g., Keep advancing project X, help me plan next steps, follow up on topics I've been repeating

Content here goes in as the **highest-priority** signal for the next generation. Good for long-running directions ("currently busy with the XX product launch").

#### What I Want Tomorrow

> e.g., Tomorrow priority: track that PR, schedule meetings, look at project X next step

Content here applies **only to the next generation**. Daily Pulse will weight it heavily when it next runs.

Good for: "things I think of at night that I want to see first thing tomorrow."

### Pulse Tasks

If a card deserves follow-through, you can convert it into a **Pulse Task**:

- **Persists across days**
- Participates in every subsequent generation as "still-open work"
- Mark **Done** or **Remove** when finished
- Batch **Clear Completed** when needed

::: tip Pulse Task vs Focus
- **Focus** — long-term direction, e.g., "working on product X"
- **Pulse Task** — concrete to-do, e.g., "fix issue #123"
:::

### Feedback History

> Feedback history is kept as long-term preference signal — every like / downvote / hide / save you've ever given shapes future curation.

Tap **"View Full Feedback History"** to:

- See every historical feedback event (card title, type, date)
- Delete an individual entry (if you misclicked)
- **Clear All** to "reset" the AI's read on you

## Advanced

### External Context

ETOS can ingest **external signals** into Daily Pulse generation. The External Context section has:

| Toggle | Effect |
| --- | --- |
| Include MCP Server Capabilities | Lets generation know what MCPs you have and recent return data |
| Include Shortcut Capabilities | Same, for Shortcut tools |
| Include Recent External Results | Recent MCP / Shortcut outputs as material |
| Include Announcements & Trend Signals | System announcements, trending topics |

**Typical patterns**:

- "Read latest email" MCP → morning Pulse includes "emails worth replying to"
- "Today's Hacker News" Shortcut → tech trends in morning briefing
- "Read calendar" MCP → cards include today's meetings

::: warning External Signal Needs You to Wire It Up
ETOS doesn't know external facts out of nothing. Daily Pulse can only use: things you've **already chatted about**, things **already saved as memories**, and things **recently fetched via MCP / Shortcuts**.

If you don't connect MCPs or write Shortcuts, the external toggles don't do much.
:::

### Background Delivery

The **Proactive Delivery** group lets ETOS schedule generation even when the app **isn't open** (requires iOS background refresh permission).

- iOS decides the **actual run time** based on usage patterns — you can't pin exact times
- "Morning Reminder 7:00" doesn't guarantee 7:00 sharp, but it'll usually land in a reasonable window before 8

### Preparation State

While generating, the page shows "Preparing today's Daily Pulse" and "System started preparing today's batch at HH:MM."

On failure you'll see an error with retry available.

### When All Cards Get Hidden

If you hide every card in today's run, the page shows "All cards this round were hidden. You can generate a fresh batch." Tap regenerate.

Frequently hiding everything teaches the AI "this style isn't wanted" — **prefer Downvote to Hide** for fine-tuning.

### Watch-Side Daily Pulse

On Apple Watch:

- **Notifications** — morning reminder arrives on the Watch
- **Quick read** — expand a notification to see card summary
- **No feedback editing** — like / downvote handling stays on iPhone

Best for: glancing at "today's overview" on wrist, full handling on iPhone.

## Next

- See exactly which signals Daily Pulse uses → [Daily Pulse Internals](/en/design/daily-pulse)
- Pair it with long-term memory → [Memory & Worldbook](/en/modules/memory-worldbook)
- Wire external sources → [Tools & MCP](/en/modules/tools-and-mcp)
