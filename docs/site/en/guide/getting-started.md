---
title: Overview
description: Never used ETOS LLM Studio before? This page walks you from download to "the AI is actually answering me" in about 10 minutes.
---

# Overview

ETOS LLM Studio is an AI client for iPhone and Apple Watch. You **bring your own API key** and connect to OpenAI, Anthropic, Google, or any OpenAI-compatible service. The app charges no subscription, takes no cut, and stores all data locally.

If you're **completely new**, treat this page as the table of contents. Walk through the three onboarding tutorials in order — each takes 5–10 minutes.

## The Shortest Path

Three steps to a working chat:

1. **Install the app** → [Install & First Launch](/en/guide/installation) (TestFlight or Xcode build; what to do right after first launch)
2. **Add an LLM provider** → [Add Your First Provider](/en/guide/first-provider) (10-step walkthrough with OpenAI / Claude / Gemini cheat sheet + error code reference)
3. **Send your first message** → [Start Your First Chat](/en/guide/first-chat) (every button around the input bar, attachments, tool switches, thinking, export)

After these three, you have a working AI assistant that can chat, accept images, and read replies aloud. **Stop here** — don't enable advanced features yet.

## Where to Go Next

Once chat is stable, pick your direction:

### Want a tour of every feature?

→ [Interface Tour](/en/guide/interface-tour)

A complete map of every sub-screen inside Settings, so you stop hunting for things.

### Want to know **why** ETOS works the way it does?

→ [Design Docs](/en/design/)

How context is assembled, which signals Daily Pulse uses, what triggers a Worldbook injection. Reading these helps you tune things correctly.

### Want to dive straight into a specific feature?

→ [Modules](/en/modules/chat-and-models)

Organized by module: Chat & Models / Tools & MCP / Skills & Shortcuts / Memory & Worldbook / Daily Pulse / Sync & Backup / Debug & Feedback.

## Vocabulary You'll Encounter

The names below show up everywhere in the app and docs. **You don't need to memorize them now** — they'll be re-explained as you encounter each. Here's a heads-up:

| Term | One-line | Where it lives |
| --- | --- | --- |
| **Provider** | An LLM vendor: OpenAI, Anthropic, Google, … | Settings → Providers & Models |
| **Model** | A specific AI: GPT-4o, Claude 3.5 Sonnet, … | Same |
| **Session** | A continuous chat thread | Chat tab |
| **Current Model** | The model used when you send a message | Settings → Current Model |
| **Multimodal** | The AI can see images, hear audio | Chat → `+` attachments |
| **MCP** (Model Context Protocol) | Open protocol for plugging external tools into a model — "the App Store for model tools" | Settings → MCP Tool Integration |
| **Skills** | A bundle of local scripts/resources that give the model specialized abilities | Settings → Agent Skills |
| **Shortcut Tools** | iOS Shortcuts exposed as callable tools for the model | Settings → Shortcut Tool Integration |
| **Memory** | Cross-session facts that get auto-injected next time | Settings → Memory System |
| **Worldbook** | A keyword-triggered knowledge patch | Settings → Worldbook |
| **Daily Pulse** | A scheduled "what's worth reading today" card the app proactively generates | Settings → Daily Pulse |
| **Sync & Backup** | iPhone ↔ Watch sync; ETOS bundle import/export | Settings → Sync & Backup |

::: tip Don't Enable Everything at Once
It's tempting to flip every switch on day one. **Use plain chat for a few days first**, then add memory, Worldbook, Daily Pulse, MCP. They're independent — adding them later costs you nothing.
:::

## What to Skip Early

In your first few days, avoid:

- Importing 1000+ historical conversations on day one (it'll add to first-launch time; do it after you commit to the app)
- Enabling 5+ MCP servers simultaneously (bloats every request and burns model context)
- Configuring providers from the Apple Watch (the screen is too small; configure on iPhone, sync over)
- Changing temperature / top_p / max_tokens before chat works (makes debugging much harder)

## Start Now

👉 [Install & First Launch](/en/guide/installation)
