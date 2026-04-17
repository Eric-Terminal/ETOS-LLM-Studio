# ETOS LLM Studio

![Swift](https://img.shields.io/badge/Swift-FA7343?style=flat-square&logo=swift&logoColor=white)
![Platform](https://img.shields.io/badge/Platform-iOS%20%7C%20watchOS-blue?style=flat-square&logo=apple&logoColor=white)
![License](https://img.shields.io/badge/License-GPLv3-0052CC?style=flat-square)
![Build](https://img.shields.io/badge/Build-Passing-44CC11?style=flat-square)

**A native AI client for iOS and Apple Watch. It supports OpenAI, Anthropic Claude, Google Gemini, multiple compatible providers, MCP tool calling, local RAG memory, Worldbook, Daily Pulse, Siri Shortcuts, and cross-device sync.**

[Simplified Chinese](../../README.md) | [Traditional Chinese](README_ZH_HANT.md) | [Japanese](README_JA.md) | [Русский](README_RU.md)

---

## 📸 Screenshots

| | |
|:---:|:---:|
| <img src="../../assets/screenshots/screenshot-01.png" width="300"> | <img src="../../assets/screenshots/screenshot-02.png" width="300"> |

---

## 👋 Foreword

School life can be pretty boring, and I always seem to have a lot of things I want to ask AI. At the time, most AI apps on the App Store were either absurdly expensive or too limited to be useful—especially on Apple Watch—so I ended up building one myself.

What started as a rough little app with only 1,800 lines of code and hardcoded API keys has grown into a project with **235 Swift source files and 118,070 lines of code** (including Shared / iOS / watchOS / tests). “ETOS LLM Studio” may sound a bit over the top, but in reality it is still my playground for exploring the boundaries of LLM applications.

It is no longer just a Watch app either. I have gradually expanded the iOS side into a complete experience for managing models, tools, memory, worldbooks, and Daily Pulse, and the two platforms stay in sync through the built-in sync engine.

Since I mostly use a Mac and an Apple Watch in daily life, the iPhone side still has some edges I want to polish—but I will keep improving it.

### Key Features

#### Chat and Models

*   **Native on Both Platforms**: Built natively for iOS and Apple Watch, with a consistent visual language and platform-specific interaction tuning.
*   **Session Management Enhancements**: Supports full-text session search, message index jump, folder classification, batch move, and per-session cross-device send.
*   **Multi-Model Support**: Native adapters for OpenAI, Anthropic (Claude), Google (Gemini), and compatible APIs, with in-app provider and model management.
*   **Advanced Request Configuration**: Supports custom headers, parameter expressions, and raw JSON request bodies for experimental or provider-compatible setups.
*   **Multimodal and Image Generation**: Supports voice input, image input, and AI image generation.
*   **Conversation Import/Export**: Supports importing from Cherry Studio, RikkaHub, Kelivo, and ChatGPT conversations, plus export to PDF / Markdown / TXT.
*   **Speech-to-Text (STT)**: Integrates system `SFSpeechRecognizer` streaming transcription, with real-time transcript preview and one-tap insertion.
*   **Text-to-Speech (TTS)**: Supports system TTS, cloud TTS, and automatic fallback, with separate model and playback parameter settings.

#### Display and Reading Experience

*   **Customizable Display System**: Supports custom fonts (including WOFF / WOFF2), font-slot priority, bubble/text color customization, and bubbleless UI.
*   **Font Fallback Strategy**: Supports paragraph-level and glyph-level fallback scope selection for more stable mixed-language and symbol rendering.
*   **Thinking and Content Preview**: Auto-preview for thinking content is enabled by default to reduce manual expansion.
*   **Markdown and Code Block Enhancements**: Supports syntax highlighting, copy feedback, collapse toggle, iOS code preview, Mermaid rendering, and blockquote left-border styling.

#### Tools and Automation

*   **Tool Center + Extended Tools**: Unified management for MCP, Shortcuts, and local tools, with toggles, approval policies, and session-level enablement.
*   **Agent Skills**: End-to-end skill integration with unified toggles in Tool Center, plus local file import on iOS and URL-based import on watchOS.
*   **Structured Q&A Tool (`ask_user_input`)**: Supports step-by-step single-question flow, single/multi choice exclusivity rules, custom input, and previous-question navigation.
*   **Extended Tooling Coverage**: Adds SQLite CRUD tools, web card display tools, and automatic feedback ticket submission tools.
*   **Sandbox File System Tools**: Supports search, chunked reading, diff viewing, partial edits, move / copy / delete, and other file operations.
*   **MCP Integration**: Supports remote [Model Context Protocol](https://modelcontextprotocol.io) with a full MCP client, streamable HTTP/SSE transport, reconnect handling, timeouts, handshake governance, and capability negotiation.
*   **Siri Shortcuts**: Integrates with the Shortcuts framework, supports AI invocation through shortcuts, custom tools, and URL Scheme routing.
*   **In-App File Management**: Includes a built-in file manager for browsing and managing sandbox files directly inside the app.

#### Memory and Knowledge Organization

*   **Local RAG Memory**: Embeddings can use cloud APIs, but the **vector database itself runs fully locally on SQLite**. Also supports chunking, embedding progress visualization, memory editing, and active retrieval tools.
*   **GRDB Relational Persistence**: Core persistence migrated from JSON to GRDB + SQLite, covering sessions, configuration, MCP, worldbooks, memory, feedback, shortcuts, and more.
*   **Worldbook**: A Lorebook-style system similar to SillyTavern, with background setting management, conditional triggers, session-bound isolation, system injection, and URL import.
*   **Broad Format Compatibility**: Compatible with PNG naidata, top-level JSON arrays, and `character_book` worldbook formats.
*   **Request Logs and Speed Insights**: Includes independent request logs, detailed token summaries, and streaming response speed charts.
*   **Advanced Rendering**: Built-in Markdown rendering with syntax highlighting, tables, and LaTeX math support.

#### Daily Pulse Proactive Briefing

*   **Daily Pulse**: Generates proactive cards every day so the app can surface what might be worth your attention before you even ask.
*   **Pulse Task Workflow**: Cards can be turned into follow-up tasks. Incomplete tasks persist across days and feed into the next Pulse run.
*   **Feedback History Learning**: Likes, downranks, hides, and saves become long-term preference signals that keep shaping future results.
*   **Morning Reminders and Continue Chat**: Supports scheduled reminders, notification quick actions, saving cards as sessions, and continuing into chat flows on both iOS and watchOS.

#### Sync, Debugging, and Operations

*   **Cross-Device Sync**: Built-in iOS ↔ watchOS sync engine for providers, sessions, worldbooks, tool settings, Daily Pulse data, and more, with Manifest/Delta differential sync in the main path.
*   **Sync and Backup**: Supports ETOS package export/import, full import on watchOS, startup backup with corruption self-healing, and direct POST upload of export packages to custom endpoints.
*   **In-App Feedback Assistant**: Supports feedback categories, environment collection, PoW submission flow, and dual-platform sync.
*   **Network Proxy Support**: Supports global and provider-level HTTP(S)/SOCKS proxy with authentication.
*   **Feedback Center and Notifications**: Supports in-ticket comments, developer badge display, status auto-refresh, and high-priority local notifications with deep links.
*   **LAN Debugging**: Includes a LAN debugging client, a Go-based companion service, and a built-in web console for browser-based file/session management.
*   **Localization**: Supports 8 languages — English, Simplified Chinese, Traditional Chinese (Hong Kong), Japanese, Russian, French, Spanish, and Arabic.

---

## 💸 About Pricing and Open Source

To be honest, I originally wanted to make this free software.
But the Apple Developer Program costs $99 per year, which is not exactly light for a student.

Later, an investor helped cover that fee, on the condition that I repay it through software sales (and share revenue along the way). So the App Store version charges a symbolic amount. You can think of it as helping me pay off that cost while also buying the convenience of “not having to re-sign every seven days.”

**But open source is still my bottom line.**

So the rules are simple:
1.  **If you want convenience / want to support me**: See you on the App Store, and thank you for the “Coke money.”
2.  **If you want to tinker / want it for free**: The code is right here under GPLv3. If you have a Mac and Xcode, **you can build and install it yourself with no feature differences at all**.
3.  **If you want the latest build early**: Join TestFlight 👉 [https://testflight.apple.com/join/d4PgF4CK](https://testflight.apple.com/join/d4PgF4CK)

Technology should be shared. I do not want a small price barrier to block someone who is just as curious about code as I am.

---

## 🛠️ Tech Stack

*   **Language**: Swift 6
*   **UI**: SwiftUI
*   **Architecture**: MVVM + Protocol Oriented Programming
*   **Data**: GRDB + SQLite (core persistence for sessions / configuration / memory and local vector store), JSON (import/export and compatibility formats)
*   **Networking and Transport**: URLSession (API requests), Streamable HTTP / SSE (MCP transport), WebSocket / HTTP polling (LAN debugging)
*   **AI Protocol**: Model Context Protocol (MCP)
*   **System Integrations**: Siri Shortcuts, WatchConnectivity, UserNotifications, BackgroundTasks (iOS)
*   **Dependency Management**: Swift Package Manager (current explicit dependencies: `GRDB.swift` and `swift-markdown-ui`, with transitive dependencies `networkimage` and `swift-cmark`)

---

## 🏗️ Project Architecture

The project uses a two-layer structure: a platform-independent Shared framework plus platform-specific view layers.

```
Shared/Shared/                  ← Platform-agnostic business logic (87 Swift source files)
├── ChatService.swift            ← Central singleton for sessions, messages, model selection, and request orchestration
├── APIAdapter.swift             ← API adapter layer for OpenAI / Anthropic / Gemini and related formats
├── Models.swift                 ← Core data models
├── Persistence.swift            ← Storage entry, migration bootstrap, and lifecycle coordination
├── PersistenceGRDBStore.swift   ← Core GRDB relational persistence implementation
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

ETOS LLM Studio/ETOS LLM Studio iOS App/    ← iOS view layer (44 Swift source files)
ETOS LLM Studio/ETOS LLM Studio Watch App/  ← watchOS view layer (47 Swift source files)
Shared/SharedTests/                         ← Shared-layer tests (54 Swift source files)
```

Data flow: `View → ChatViewModel → ChatService.shared → APIAdapter → LLM API`, with UI updates driven through Combine subjects.

---

## 🚀 Build Guide

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

This README was last revised on April 18, 2026 (after 31d1e21). The project moves quickly, so if the README falls behind the code, the commit history is the best source of truth.
