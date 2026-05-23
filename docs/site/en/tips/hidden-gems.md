---
title: Hidden Gems
description: Things the app doesn't announce but feel like "I wish I'd known earlier" once you've used it — sorted by scenario.
---

# Hidden Gems

For people who think "I know this app does a lot, but a lot of stuff just isn't going to discover itself."

The most important one up front: in ETOS, "hidden tricks" **often hide in gestures, not in deep menus**.

## Gestures

### 1. Always Try "Long-press + Swipe"

When you see a row, card, message, list item, or record — don't just tap. The reliable exploration order is:

1. **Tap once** to see the normal flow
2. **Long-press** to check the context menu
3. **Swipe left or right** to look for quick actions

This rule is **near-universal** in ETOS, particularly in:

- Session list (long-press → Move / Rename / Delete)
- Providers & models list
- Memory and session summaries (swipe left to delete, swipe right to archive)
- Worldbook entries
- Daily Pulse feedback history
- File and log lists
- Chat messages (long-press is the biggest Easter egg surface)

If you ever think "surely this thing has more than one tap action" — long-press, then swipe.

### 2. Long-press in Chat = Hidden Feature Treasure Chest

Each message's long-press menu has 8–10 actions, including:

- **Create Prompt Branch** (prompt only, or copy message history too)
- **Export Up to This Message (with context)** — truncate and export
- **Token Info** + **Thinking Duration** — metadata for reasoning models
- **Edit Message** (yes, including the AI's reply)
- **Quote** — quote this message in your next input

Details in [Start Your First Chat](/en/guide/first-chat).

### 3. The Session List Search Field Is Full-Text, Not Title-Only

The search field at the top of the session list (placeholder "Search session titles or messages") does **full-text content search**, not just titles.

Tapping a result **jumps to that specific historical message** — way faster than scrolling.

## Configuration

### 4. Get One Model Working End-to-End Before Splitting Roles

ETOS lets you pick separate models for chat / TTS / Daily Pulse / STT / embedding. But first time around, **get one stable model working end-to-end**, then split. Saves 90% of the debugging time.

### 5. More Tools ≠ Better

First-timers see MCP / local tools / Shortcuts / Skills and **enable all of them at once**. Result:

- Half the model's context is eaten by tool descriptions
- When something breaks, you can't tell which tool is to blame
- Approval bubbles keep popping up

A more practical approach:

- **Daily chat sessions: only essential tools**
- **Workflow sessions: enable a dedicated tool set**
- **Decide approval policy before allowing auto-execution**

### 6. Memory vs Worldbook — Simple Decision Rule

| This piece of info … | Goes to |
| --- | --- |
| Gets used repeatedly, like a knowledge block | **Memory** |
| Only useful when a specific keyword / scene appears | **Worldbook** |

Maintenance cost drops a lot.

### 7. Multi-Key with English Commas

The Provider's API Key field supports rotation:

```
sk-aaaaaaaaaa,sk-bbbbbbbbbb,sk-cccccccccc
```

Each request rotates; if one key trips 429, the next is used. Free / trial keys stitched together last a while.

### 8. `{api_key}` Is a Placeholder, Not a Literal

Both Provider's "Header Overrides" and MCP's header overrides support placeholders like `{api_key}` / `{token}`. They get substituted with the current key:

```
Authorization=Bearer {api_key}
X-Custom-Auth=xxx-{api_key}-yyy
```

Use for services with non-standard auth headers.

## Usage Habits

### 9. Daily Pulse's Real Key Is "Feedback"

If you **just look at cards without giving feedback**, it evolves slowly.

The four buttons — **Like / Downvote / Hide / Save as Conversation** — improve quality more than model-hopping. **Save as Conversation** is the strongest positive signal.

### 10. "Tomorrow's Curation" Is For Next Time, Not This Time

Daily Pulse has two text inputs:

- **Current Focus** — long-term direction, applied every generation
- **What I Want Tomorrow** — **applies only to the next generation**

Things you think of at night for "tomorrow morning's view" go into "Tomorrow."

### 11. Debugging Tools Save UI Hopping

When you suspect a problem is about **files, config, or requests**, jump to **Settings → Extended Features → App Logs / Advanced Diagnostics / Feedback Helper**.

They let you **see data directly** instead of guessing inside the UI.

### 12. Import/Export Is Migration, Not Just Backup

Beyond backup, ETOS bundles work for:

- **Switching devices**
- **Cross-account / cross-environment migration**
- **Save a stable version before big changes** — instant rollback if anything goes wrong

## Apple Watch

### 13. Let the iPhone Prep for the Watch

The comfortable two-device flow:

1. **iPhone**: configure models, tools, display preferences
2. **Sync**: bring the environment to the Watch
3. **Watch**: focus on chat, alerts, quick follow-up

**Don't try to do complex setup on the Watch** — screen too small, efficiency terrible.

## Final Recommendations

### 14. Build Your Own "Usage Layers"

A simple layering helps:

| Use case | Config |
| --- | --- |
| **Daily chat** | Most stable model + minimum tools + auto-approve memory write |
| **Specialized tinkering** | Advanced params + all tools + MCP / Skills when needed |
| **Fragments of time (Watch)** | Receive reminders + short-turn chat + no config |

No matter how many features pile up, you don't end up with a soup.

### 15. When You Can't Find Something, Ask "Is This Governance or Execution?"

ETOS's main screen has only "Chat + Settings" tabs:

- **Execution** (chatting, attachments, model switching) → Chat
- **Governance** (providers, tools, memory, worldbook, sync, Daily Pulse config) → Settings

Following this rule, **hit rate is 90%+**.

## Next

- How to use the Watch end → [Using Apple Watch](/en/tips/watch-usage)
- Common questions → [FAQ](/en/faq/)
