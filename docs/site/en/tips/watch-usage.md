---
title: Using Apple Watch
description: The Watch isn't a remote, but it also shouldn't be "the only entry point." This page shows what the Watch is genuinely good at.
---

# Using Apple Watch

The Watch end of ETOS LLM Studio **isn't an accessory remote**, but it also **shouldn't be "the place where everything happens."** The most comfortable experience comes from clear **two-device division of labor**.

::: tip Read First
We assume you already have basic chat working on iPhone and have set up [Sync & Backup](/en/modules/sync-backup) so both devices are in sync.
:::

## What the Watch Can / Can't Do

### Can (and Does Well)

| Task | Why it suits the Watch |
| --- | --- |
| **Start a new conversation** | Raise wrist → Crown to home → app grid → send |
| **Voice input** | Easier than on the phone — designed for the mic |
| **Receive Daily Pulse pushes** | Glance at today's card summary on wake |
| **Continue an existing session** | Reply on the go — walking, queueing, waiting |
| **Short-turn chat in fragmented time** | One-sentence question → one-sentence answer → done |

### Can't (or Painful)

| Task | Why it's not Watch-friendly |
| --- | --- |
| Add / edit providers | Too many fields; typing API keys is excruciating |
| Fill proxy host / username / password | Same |
| Import worldbooks / bulk memories | Too small to see entries |
| Tune display system | Fonts / background / blur need previews on a big screen |
| Manage MCP servers | URLs / Bearer Tokens / OAuth flows all need iPhone |
| Tool approval policies | Need to review per-tool, screen isn't enough |
| File feedback | Screenshots and logs are easier on iPhone |

## Why Split Like This

**Not because the Watch can't** — because:

- **Watch input is more expensive** — typing is hard, deep menus are harder
- **Deep configuration paths suit big screens** — long forms are bad on the wrist
- **The phone is better for bulk management and debugging** — needs space + multiple panes

## Recommended Workflow

### First-time Setup

1. Configure providers, models, and base preferences on **iPhone**
2. Open **Settings → Display & Experience → Sync & Backup** and enable Apple Watch sync
3. Wait for the sync status to show **"Sync Successful"**
4. Treat the Watch as a **ready-to-go "wrist client"**

### Day-to-day

| Scenario | Device |
| --- | --- |
| Read Daily Pulse push in the morning | Watch quick glance |
| Want to go deeper on a card | Switch to iPhone |
| Random idea while walking | Watch voice input |
| AI reply is too long to comfortably read | Continue on iPhone, read at home |
| Want to like / hide a card | iPhone (notifications are enough on the Watch) |

## What the Watch Is Actually For

### Daily Chat

- **Short back-and-forth messages**
- **Continue an existing session** (synced over)
- **Voice input supplement** (Crown or wake-to-talk)

### Proactive Alerts

- **Receive Daily Pulse pushes**
- **Continue into chat from notification actions**

### Lightweight Consumption

- **Read short replies**
- **Quick-scan highlights**
- **Switch to phone when deeper action is needed**

## What Not to Do

- ❌ First-time configure **all providers** on the Watch
- ❌ Use the **Watch for first round of complex tool experiments**
- ❌ Edit a lot of config on **both ends simultaneously** before sync is stable (causes conflicts)
- ❌ Edit **long text** on the Watch — use voice if you can

## When Sync Is Flaky

See [Sync & Backup → Advanced → Sync Troubleshooting](/en/modules/sync-backup#sync-troubleshooting).

Common causes:

- Bluetooth off / different Wi-Fi → check connection
- Both ends editing simultaneously → last write wins → **adopt "configure on iPhone only" as a rule**

## Next

- The full sync mechanism → [Sync & Backup](/en/modules/sync-backup)
- More gesture tricks → [Hidden Gems](/en/tips/hidden-gems)
