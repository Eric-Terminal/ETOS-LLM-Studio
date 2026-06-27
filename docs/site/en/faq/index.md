---
title: FAQ
description: Common questions after installation, organized by topic.
---

# FAQ

Grouped by topic. If your question isn't here, dive into the relevant tutorial, or file a ticket via **Settings → Extended Capabilities → Extended Features → Feedback Helper**.

## About the App

### Is this an iPhone app or a Watch app?

**Both**. ETOS LLM Studio runs on both iPhone and Apple Watch, with sync between them. See [Sync & Backup](/en/modules/sync-backup).

### Do I need an Apple Watch to use it?

**No**. The Watch is a featured surface, but the iPhone end is fully complete on its own.

### Does this only support OpenAI?

**No**. Four API formats are supported:

- **OpenAI Compatible** (Chat Completions) — covers official OpenAI and nearly every third-party relay
- **OpenAI Responses** — OpenAI's newer endpoint
- **Anthropic** — Claude
- **Gemini** — Google

If your service speaks one of these, you can connect. See [Add Your First Provider](/en/guide/first-provider).

### Is the app paid?

**No**. The app is free with no subscription. You pay only the **LLM provider** you connect (OpenAI / Anthropic / Google, etc.).

### Where does my data go?

**By default, nowhere**. Everything stays in the local SQLite database. Data leaves only if **you** explicitly:

- Enable iCloud sync (encrypted upload to your iCloud)
- Enable Apple Watch sync (LAN direct, no external server)
- Upload backups to your S3 / R2
- Send a conversation as a request to your connected LLM (intrinsic to using the model API)

See [Sync & Backup](/en/modules/sync-backup).

## Setup & Configuration

### Where do most people get stuck first?

**Provider configuration**. The advice: **connect only one stable model first**, get text chat working, then enable image, voice, tools, and proxies. See [Add Your First Provider](/en/guide/first-provider).

### Why do so many features feel buried?

ETOS packs everything into the **Settings tab**, keeping the main UI for chat. That keeps daily use clean but means [Interface Tour](/en/guide/interface-tour) is worth a read.

When you can't find something, use this rule:
- **Execution** (chat, attachments) → Chat tab
- **Governance** (providers, tools, memory, worldbook, sync) → Settings tab

### Chat says "Select a model to start"

Go to **Settings → Current Model → Model** and **explicitly pick** one.

If the list is empty ("No models available. Please enable one under Providers & Models."), you added a provider but **didn't enable a model row** — open Providers & Models and toggle on the model you want.

### My requests keep failing with "Authentication failed"

Usually an API key issue:

1. **Re-copy** the key from the vendor console
2. Make sure there's **no leading/trailing whitespace**
3. **Don't** prepend `Bearer ` manually — the app adds it
4. Check if the key has expired

See [Add Your First Provider → Common Errors](/en/guide/first-provider#common-errors).

## Feature Choices

### Memory vs Worldbook — how do I choose?

| This info … | Goes in |
| --- | --- |
| Used repeatedly, like a knowledge block | **Memory** |
| Only useful when a specific keyword / scene appears | **Worldbook** |

Simple examples:
- "Reply in Chinese by default" → Memory
- "When Character X shows up, recall their background" → Worldbook

See [Memory & Worldbook](/en/modules/memory-worldbook).

### What's Daily Pulse?

A daily auto-generated stack of cards on "what's worth looking at today," based on your local signals (recent chats, memory, feedback). See [Daily Pulse](/en/modules/daily-pulse) and [Daily Pulse Internals](/en/design/daily-pulse).

### Are Tools and MCP required?

**No**. You can use ETOS purely as a chat client. But if you want richer workflows (let the AI search files, call external services, run a Shortcut), the tool system is **well worth** the time. See [Tools & MCP](/en/modules/tools-and-mcp).

### Is memory cloud-hosted?

**No**. Embeddings call a cloud API (during vectorization), but the **vector database itself is local SQLite**.

### Can different sessions use different models?

Yes. The **top-right of the chat screen** switches the current session's model. It only affects this session, not the default.

## Multi-device / Sync

### Do I have to enter API keys on the Watch?

**No**. Strongly recommended to **do all configuration on iPhone** and let sync carry it to the Watch. See [Using Apple Watch](/en/tips/watch-usage).

### Does iCloud sync include API keys?

**Yes**. When iCloud sync is on, all data (including API keys) is **encrypted and uploaded to your iCloud**. Apple can't see it, but make sure your Apple ID has **two-factor authentication**.

If you don't want keys on iCloud, **use only Apple Watch sync** (LAN direct, never uploads).

### Will uninstalling lose my data?

**Yes** — irrecoverably. **Before uninstalling**, take a Full Snapshot (Settings → Display & Experience → Sync & Backup → Database Snapshot → Full Snapshot) and stash it on iCloud Drive or S3.

## Debugging & Feedback

### How do I debug effectively?

Identify which layer is broken:

| Symptom | Likely layer |
| --- | --- |
| No model connects | Network / proxy |
| Some models don't connect | That provider's key / Base URL |
| Models connect but reply is off | System prompt / memory / worldbook interference |
| Tools can't be called | Approval policy / Tool Center master switch / worldbook isolation |
| Sync down | Both ends on same network? / iCloud status |

Then jump to the relevant tutorial. See [Debug & Feedback](/en/modules/debug-feedback).

### How do I file effective feedback?

```
Settings → Extended Capabilities → Extended Features → Feedback Helper → + New Ticket
```

Include:

- **Exact reproduction steps** (taps, fields filled)
- **Environment info** (auto-captured)
- **App logs** (redacted, the date folders are easy to find)
- **Screenshots** (optional)

Submit after the PoW completes. Status syncs automatically.

### My ticket hasn't been answered

ETOS is open-source / spare-time pace, not 24×7 support. **First response usually within 24–72 hours**. If a week passes, follow up on the ticket or duplicate on [GitHub Issues](https://github.com/Eric-Terminal/ETOS-LLM-Studio/issues).

## Other

### Can I contribute code / file a PR?

Yes. Repo: [github.com/Eric-Terminal/ETOS-LLM-Studio](https://github.com/Eric-Terminal/ETOS-LLM-Studio).

Before opening a PR, read the
[contribution guide](https://github.com/Eric-Terminal/ETOS-LLM-Studio/blob/main/CONTRIBUTING.md).
All contributions require signing the
[CLA](https://github.com/Eric-Terminal/ETOS-LLM-Studio/blob/main/CLA.md):
check the statement in your first PR template, or comment
`I have read the CLA Document and I hereby sign the CLA.`.

### How do I contribute to this doc site?

Source lives in `docs/site/`. Local preview:

```bash
cd docs/site
pnpm install
pnpm docs:dev
```

Chinese version at the root, English version mirrored under `en/`. Submit a PR after edits.

### Still have a question?

- Try [Overview](/en/guide/getting-started) — maybe a step was skipped
- Try [Interface Tour](/en/guide/interface-tour) — maybe the feature is just hiding
- Try [Hidden Gems](/en/tips/hidden-gems) — maybe a gesture was missed
- File a ticket / GitHub Issue
