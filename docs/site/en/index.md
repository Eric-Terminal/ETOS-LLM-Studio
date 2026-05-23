---
layout: home

hero:
  name: ETOS LLM Studio
  text: A Native AI Client for iPhone + Apple Watch
  tagline: Bring your own API key. Local-first storage. Two-way device sync. Zero middle server. Talk to OpenAI / Claude / Gemini / any OpenAI-compatible service — with memory, worldbook, MCP, Skills, Daily Pulse, and Shortcut tools.
  image:
    src: /images/hero/etos-hero.jpg
    alt: ETOS LLM Studio
  actions:
    - theme: brand
      text: First chat in 10 minutes
      link: /en/guide/getting-started
    - theme: alt
      text: Module deep dives
      link: /en/modules/chat-and-models
    - theme: alt
      text: GitHub
      link: https://github.com/Eric-Terminal/ETOS-LLM-Studio

features:
  - icon: 📱
    title: Native on iPhone + Apple Watch
    details: Both devices have their own interaction paths, reorganized for each screen size — not a phone app awkwardly shrunk onto a watch.
  - icon: 🔌
    title: Your Key, Your Data
    details: Model requests go straight from the device to the provider — no middle server. Conversations live in a local SQLite database; export an ETOS bundle any time.
  - icon: 🧠
    title: Long-term Memory + Worldbook + Daily Pulse
    details: More than one-shot chat. Cross-session facts, keyword-triggered knowledge patches, scheduled proactive briefings — all wired into the conversation flow.
  - icon: 🧰
    title: MCP / Skills / Shortcuts / File Tools
    details: Give the model "plugin" capabilities. MCP for external services, Skills for local capability bundles, Shortcuts to let the model trigger iOS automations.
  - icon: 🎛️
    title: Advanced Request Configuration
    details: Multi-key rotation, custom headers, parameter expressions, raw JSON body, per-provider and global proxies — whatever weird "compatible" endpoint exists, you can probably hit it.
  - icon: 🔄
    title: Cross-device Sync + Third-party Import
    details: Direct LAN sync between iPhone and Watch. Migrate from Cherry Studio, RikkaHub, Kelivo, or the official ChatGPT export.
---

## What This Doc Site Does

ETOS LLM Studio hides every feature inside Settings and keeps the main UI for chat. That keeps daily use clean, but it also means **lots of features are easy to miss** even after you install the app.

This documentation has three jobs:

1. **Step-by-step tutorials** — from install to first reply, with exact taps, fields, and "you succeeded when you see X."
2. **Feature deep dives** — every module is introduced as *what it is, what problem it solves, what happens without it*, then the configuration.
3. **Design rationale** — if you want to know **why** ETOS works the way it does (context assembly, Daily Pulse signal sources, Worldbook injection rules), the design docs cover it.

## Where to Start

| You're … | Start here |
| --- | --- |
| New, haven't downloaded | [Overview](/en/guide/getting-started) (10-minute path) |
| Installed but stuck | [Add Your First Provider](/en/guide/first-provider) |
| Chatting; want a full tour | [Interface Tour](/en/guide/interface-tour) |
| Going deep on one feature | [Modules](/en/modules/chat-and-models) |
| Curious about the design | [Design](/en/design/) |
| Hunting for tricks | [Hidden Gems](/en/tips/hidden-gems) |
| Stuck on a problem | [FAQ](/en/faq/) |

## Screen Previews

Many features don't announce themselves. This doc site fills in their physical locations, recommended use order, and the explanations the app deliberately keeps off-screen.

<div class="etos-gallery">
  <figure>
    <img src="/images/screenshots/screenshot-01.png" alt="Chat screen">
    <figcaption>The chat screen isn't just a message list. Model switching, attachments, tool toggles, thinking, TTS read-aloud, and message export all live on one screen.</figcaption>
  </figure>
  <figure>
    <img src="/images/screenshots/screenshot-02.png" alt="Settings screen">
    <figcaption>Settings is the cockpit. Providers, tools, memory, sync, Daily Pulse, and the feedback system are all grouped here.</figcaption>
  </figure>
</div>
