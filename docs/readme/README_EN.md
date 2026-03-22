# ETOS LLM Studio

![Swift](https://img.shields.io/badge/Swift-FA7343?style=flat-square&logo=swift&logoColor=white)
![Platform](https://img.shields.io/badge/Platform-iOS%20%7C%20watchOS-blue?style=flat-square&logo=apple&logoColor=white)
![License](https://img.shields.io/badge/License-GPLv3-0052CC?style=flat-square)
![Build](https://img.shields.io/badge/Build-Passing-44CC11?style=flat-square)

**A native AI client for iOS and Apple Watch. It supports OpenAI, Anthropic Claude, Google Gemini, MCP tool calling, local RAG memory, Worldbook, Daily Pulse, Siri Shortcuts, and cross-device sync.**

[Simplified Chinese](../../README.md) | [Traditional Chinese](README_ZH_HANT.md) | [Japanese](README_JA.md)

---

## ✨ Recent Highlights

*   **Daily Pulse**: Generates proactive briefing cards by combining recent chats, long-term memory, request logs, feedback history, next-day curation input, external signals, and follow-up tasks.
*   **Pulse Tasks and Feedback Loop**: Cards can be liked, downranked, hidden, saved as sessions, continued as chats, or converted into tasks; long-term preferences feed back into later runs.
*   **Morning Delivery and Background Preparation**: iOS now supports background prewarm, morning reminders, and notification quick actions, while watchOS also has the full entry, review, and continue-chat flow.
*   **Text-to-Speech (TTS)**: Supports system TTS, cloud TTS, and automatic fallback, with separate TTS model selection and provider parameters.

---

## 📸 Screenshots

| | |
|:---:|:---:|
| <img src="../../assets/screenshots/screenshot-01.png" width="300"> | <img src="../../assets/screenshots/screenshot-02.png" width="300"> |

---

## 👋 Foreword

School life can be pretty boring, and I always seem to have a lot of things I want to ask AI. At the time, most AI apps on the App Store were either absurdly expensive or too crippled to be useful—especially on Apple Watch—so I ended up building one myself.

What started as a rough little app with only 1,800 lines of code and hardcoded API keys has grown into a project with **186 Swift source files and 88,359 lines of code** (including Shared / iOS / watchOS / tests). “ETOS LLM Studio” may sound a bit over the top, but in reality it is still my playground for exploring the edges of LLM applications.

It is no longer just a Watch app either. I have gradually filled out the iOS side into a more complete experience for managing models, tools, memory, worldbooks, and Daily Pulse, and the two platforms can sync through the built-in sync engine.

Since I mostly use a Mac and an Apple Watch in daily life, the iPhone side still has some corners I want to polish further—but I will keep improving it.

### Key Features

#### Chat and Models

*   **Native on Both Platforms**: Built natively for iOS and Apple Watch, with a consistent overall style and platform-specific interaction tuning.
*   **Multi-Model Support**: Native adapters for OpenAI, Anthropic (Claude), Google (Gemini), and compatible APIs, with in-app provider and model management.
*   **Advanced Request Configuration**: Supports custom headers, parameter expressions, and raw JSON request bodies for more experimental or provider-compatible setups.
*   **Multimodal and Image Generation**: Supports voice input, image input, and AI image generation.
*   **Text-to-Speech (TTS)**: Supports system TTS, cloud TTS, and automatic fallback, with separate TTS model selection and playback parameters.

#### Tools and Automation

*   **Tool Center + Extended Tools**: Unified management for MCP, Shortcuts, and local tools, with toggles, approval policies, and session-level enablement.
*   **Sandbox File System Tools**: Supports search, chunked reading, diff viewing, partial edits, move / copy / delete, and other file operations.
*   **MCP Integration**: Supports remote [Model Context Protocol](https://modelcontextprotocol.io) with a full MCP client, streamable HTTP/SSE transport, reconnect handling, timeouts, handshake governance, and capability negotiation.
*   **Siri Shortcuts**: Integrates with the Shortcuts framework, supports AI invocation through shortcuts, custom tools, and URL Scheme routing.
*   **In-App File Management**: Includes a built-in file manager for browsing and managing sandbox files directly inside the app.

#### Memory and Knowledge Organization

*   **Local RAG Memory**: Embeddings can use cloud APIs, but the **vector database itself runs fully locally on SQLite**. It also supports chunking, embedding progress visualization, memory editing, and active retrieval tools.
*   **Worldbook**: A Lorebook-style system similar to SillyTavern, with background setting management, conditional triggers, session-bound isolation, system injection, and URL import.
*   **Broad Format Compatibility**: Compatible with PNG naidata, top-level JSON arrays, and `character_book` worldbook formats.
*   **Request Logs and Speed Insights**: Includes independent request logs, detailed token summaries, and streaming response speed charts.
*   **Advanced Rendering**: Built-in Markdown rendering with syntax highlighting, tables, and LaTeX math support.

#### Daily Pulse Proactive Briefing

*   **Daily Pulse**: Generates a set of proactive cards each day so the app can surface what might be worth your attention before you even ask.
*   **Pulse Task Workflow**: Cards can be turned directly into follow-up tasks. Incomplete tasks persist across days and are reused in the next Pulse run.
*   **Feedback History Learning**: Likes, downranks, hides, and saves become long-term preference signals that keep shaping future results.
*   **Morning Reminders and Continue Chat**: Supports scheduled reminders, notification quick actions, saving cards as sessions, and continuing into chat flows on both iOS and watchOS.

#### Sync, Debugging, and Operations

*   **Cross-Device Sync**: Built-in iOS ↔ watchOS sync engine for providers, sessions, worldbooks, tool settings, Daily Pulse data, and more.
*   **In-App Feedback Assistant**: Supports feedback categories, environment collection, PoW submission flow, and dual-platform sync.
*   **LAN Debugging**: Includes a LAN debugging client that can work with a companion desktop tool to manage in-app files or inspect real-time debug logs from a browser.
*   **Localization**: Supports English, Simplified Chinese, Traditional Chinese (Hong Kong), Japanese, and Russian.

---

## 💸 About Pricing and Open Source

To be honest, I originally wanted to make this free software.
But the Apple Developer Program costs $99 per year, which is not exactly light for a student.

Later, an investor helped cover that fee, on the condition that I repay it through software sales (and share revenue along the way). So the App Store version charges a symbolic amount. You can think of it as helping me pay off that cost while also buying the convenience of “not having to re-sign every seven days.”

**But open source is still my bottom line.**

So the rules are simple:
1.  **If you want convenience / want to support me**: See you on the App Store, and thank you for the “Coke money.”
2.  **If you want to tinker / want it for free**: The code is right here under GPLv3. If you have a Mac and Xcode, **you can build and install it yourself with no feature differences at all**.

Technology should be shared. I do not want a small price barrier to block someone who is just as curious about code as I am.

---

## 🛠️ Tech Stack

*   **Language**: Swift 6
*   **UI**: SwiftUI
*   **Architecture**: MVVM + Protocol Oriented Programming
*   **Data**: SQLite (local vector store), JSON (configuration and data persistence)
*   **Networking and Transport**: URLSession (API requests), Streamable HTTP / SSE (MCP transport), WebSocket / HTTP polling (LAN debugging)
*   **AI Protocol**: Model Context Protocol (MCP)
*   **System Integrations**: Siri Shortcuts, WatchConnectivity, UserNotifications, BackgroundTasks (iOS)
*   **Dependency Management**: Swift Package Manager (current explicit dependency: `swift-markdown-ui`, with transitive dependencies `networkimage` and `swift-cmark`)

---

## 🏗️ Project Architecture

The project uses a two-layer structure: a platform-independent Shared framework plus platform-specific view layers.

```
Shared/Shared/                  ← Platform-agnostic business logic (69 Swift source files)
├── ChatService.swift            ← Central singleton for sessions, messages, model selection, and request orchestration
├── APIAdapter.swift             ← API adapter layer for OpenAI / Anthropic / Gemini and related formats
├── Models.swift                 ← Core data models
├── Persistence.swift            ← Configuration and data persistence
├── DailyPulse.swift             ← Daily Pulse engine, cards, feedback, and task data
├── DailyPulseDeliveryCoordinator.swift ← Morning reminders, delivery state, and preparation window coordination
├── Memory/                      ← Memory subsystem (chunking, embeddings, storage)
├── SimilaritySearch/            ← Local vector database (SQLite)
├── MCP/                         ← Model Context Protocol client and transport layer
├── Feedback/                    ← In-app feedback assistant (collection, signing, storage, upload)
├── Worldbook/                   ← Worldbook engine, import, and export
├── Sync/                        ← iOS ↔ watchOS sync engine
├── TTS/                         ← Text-to-speech playback, settings, and presets
├── Shortcuts/                   ← Siri Shortcuts and URL router integration
├── AppToolManager.swift         ← Local tools and tool catalog governance
├── StorageBrowserSupport.swift  ← File browsing and management support
└── LocalDebugServer.swift       ← LAN debugging client

ETOS LLM Studio/ETOS LLM Studio iOS App/    ← iOS view layer (41 Swift source files)
ETOS LLM Studio/ETOS LLM Studio Watch App/  ← watchOS view layer (43 Swift source files)
Shared/SharedTests/                         ← Shared-layer tests (30 Swift source files)
```

Data flow: `View → ChatViewModel → ChatService.shared → APIAdapter → LLM API`, with UI updates driven through Combine subjects.

---

## 🚀 Compilation Guide

If you want to build it yourself:

1.  **Clone the project**:
    ```bash
    git clone https://github.com/Eric-Terminal/ETOS-LLM-Studio.git
    ```
2.  **Requirements**:
    *   Xcode 26.0+
    *   watchOS 26.0+ SDK
    *   (If your environment does not match exactly, you can adjust compatibility yourself.)
3.  **Open the project**:
    Open `ETOS LLM Studio.xcworkspace` (**workspace**, not xcodeproj).
    On first launch, Xcode will automatically resolve and fetch Swift Package dependencies.
4.  **Run**:
    Select the `ETOS LLM Studio Watch App` or `ETOS LLM Studio iOS App` target, connect a device (or simulator), and press Command + R.
5.  **Configure**:
    After launching, add your API key in Settings. I strongly recommend using the “LAN Debugging” feature to push prepared JSON configuration files straight into `Documents/Providers/` (because who really wants to type an API key on an Apple Watch?).

---

## 📬 Contact

*   **Developer**: Eric Terminal
*   **Email**: ericterminal@gmail.com
*   **GitHub**: [Eric-Terminal](https://github.com/Eric-Terminal)

---

This README was last revised on March 22, 2026, after 3245a90. The project moves quickly, so if the README falls behind the code, the commit history is the best source of truth.
