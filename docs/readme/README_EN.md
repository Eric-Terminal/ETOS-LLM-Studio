# ETOS LLM Studio

![Swift](https://img.shields.io/badge/Swift-FA7343?style=flat-square&logo=swift&logoColor=white)
![Platform](https://img.shields.io/badge/Platform-iOS%20%7C%20watchOS-blue?style=flat-square&logo=apple&logoColor=white)
![License](https://img.shields.io/badge/License-GPLv3-0052CC?style=flat-square)
![Build](https://img.shields.io/badge/Build-Passing-44CC11?style=flat-square)

**A native AI and agent client for iOS and Apple Watch. It supports OpenAI, Anthropic Claude, Google Gemini, and on-device GGUF / llama.cpp models, together with per-session Chat / Agent modes, local Linux, Browser Agent, 64 Apple-native capability tools, MCP, executable Agent Skills, cross-conversation collaboration, local RAG memory, Live Activities, and cross-device sync.**

[Simplified Chinese](../../README.md) | [Traditional Chinese](README_ZH_HANT.md) | [Japanese](README_JA.md) | [Русский](README_RU.md)

---

## 📸 Screenshots

| | |
|:---:|:---:|
| <img src="../../assets/screenshots/screenshot-01.png" width="300"> | <img src="../../assets/screenshots/screenshot-02.png" width="300"> |

---

## 👋 Foreword

School life can be pretty boring, and I always seem to have a lot of things I want to ask AI. At the time, most AI apps on the App Store were either absurdly expensive or too limited to be useful—especially on Apple Watch—so I ended up building one myself.

What started as a rough little app with only 1,800 lines of code and hardcoded API keys has grown into a project with **971 Swift source files and 362,394 lines of Swift code** (project Swift only; the llama.cpp and iSH submodules and VitePress doc-site dependencies are not included). “ETOS LLM Studio” may sound a bit over the top, but in reality it is still my playground for exploring the boundaries of LLM applications.

It is no longer just a Watch app either. Both iOS and watchOS can manage cloud models, local GGUF weights, tools, memory, worldbooks, and Daily Pulse. Agents can also control a governed browser, call Apple-native capabilities, or run commands and Skill scripts inside the app's local Linux environment. The built-in sync engine keeps both platforms connected.

Since I mostly use a Mac and an Apple Watch in daily life, the iPhone side still has some edges I want to polish—but I will keep improving it.

### Key Features

#### Chat and Models

*   **Native on Both Platforms**: Built natively for iOS and Apple Watch, with a consistent visual language and platform-specific interaction tuning. On iOS, the session list uses a card-style layout with clear folder/session grouping, and switches to a fixed dual-column sidebar in landscape.
*   **Session Management Enhancements**: Supports full-text session search, in-context match preview, message-index jump, folder classification, Finder-style color tags, quick filtering, nested moves, batch operations, a full-screen session management entry, per-session cross-device send, and infinite-scroll history loading.
*   **Multi-Model Support**: Native adapters for OpenAI Chat, OpenAI Responses, Anthropic (Claude), and Google (Gemini), with in-app provider/model management, model-list fetching, and long-press drag ordering for providers.
*   **On-Device Local Models**: Imports GGUF weights as a “Local Models” provider, executed through a llama.cpp C ABI bridge. It supports streaming output, GGUF Jinja chat templates, local tool-call parsing, reasoning-content parsing, local embedding-model routing, and detached background completion.
*   **Advanced Local Model Tuning**: Each GGUF weight can override context size, output limit, GPU layers, batch / ubatch, KV offload, flash attention, seed, sampler chain, grammar, repetition penalties, chat-template passthrough, and more. Common llama.cpp-style CLI parameter import, model-cache control, and iOS high-memory entitlement support are also included.
*   **Advanced Request Configuration**: Supports custom headers, parameter expressions, structured request controls, key/value payload editing, raw JSON request bodies, and request preview for experimental or provider-compatible setups.
*   **Message Regex Rules**: Supports rule-based rewriting of outgoing and incoming messages, manageable as multiple rules from the preferences and quickly reachable from the provider page.
*   **Single Assistant Reply Rewrite**: Lets you rewrite one historical assistant reply in place, optionally referencing other versions of the same message, without rerunning the whole conversation.
*   **Model Pricing and Cost Estimation**: Lets you configure per-model local prices (including tiered price ranges) and automatically estimates the cost of each message based on token usage.
*   **Multimodal and Image Generation**: Supports voice, image, and file attachments; images can go through a dedicated OCR channel, file attachments are textified before sending, and image generation has been consolidated into the assistant image gallery.
*   **Conversation Import/Export**: Supports importing from ETOS / `.elsbackup`, Cherry Studio, RikkaHub, Kelivo, ChatBox, and ChatGPT conversations, plus export to PDF / Markdown / TXT.
*   **Speech-to-Text (STT)**: Integrates system `SFSpeechRecognizer` streaming transcription. The iOS / watchOS recording flow now lives inside the chat composer, with real-time transcription, direct-audio sending, and transcript insertion.
*   **Text-to-Speech (TTS)**: Supports system TTS, cloud TTS, and automatic fallback, with separate model and playback parameter settings.
*   **Concurrent Session Requests**: Each session keeps its own request state, with per-session cancellation, background-completion notifications, and tap-to-jump back to the originating chat.

#### Display and Reading Experience

*   **Customizable Display System**: Supports custom fonts (including WOFF / WOFF2), font scale, font-slot priority, bubble/text color customization, chat color profiles, time-based color switching, and a bubbleless assistant UI.
*   **Local Performance Monitor**: On iOS, local-model chats can show CPU, Metal, and memory usage above the composer. The panel supports collapsing, dragging, touch passthrough, and position persistence.
*   **Bubble Toolbar**: A configurable toolbar can be attached below each chat bubble — single-row horizontal scroll, optional outer border, separate default items for iOS and watchOS per user/assistant role, and drag-to-reorder on watchOS.
*   **Font Fallback Strategy**: Supports paragraph-level and glyph-level fallback scope selection for more stable mixed-language and symbol rendering.
*   **Thinking and Tool Timeline**: Includes rolling thinking preview, custom/responsive preview height, hidden full reasoning while streaming, thinking-time tracking, asynchronous thinking summaries, tool-call connected timeline, error-retry resumption, and multi-version reply switching. Tool approval has been redesigned as a native Q&A sheet with row/column option layout.
*   **Markdown and Code Block Enhancements**: Supports syntax highlighting, copy feedback, collapse toggle, iOS code preview, Mermaid rendering, SwiftMath formulas, blockquote left-border styling, streaming tail fade-in, and shimmer animation.
*   **watchOS Image Reading**: Markdown images and generated images support Digital Crown zoom and drag, so even small screens are good for actually looking at images.

#### Tools and Automation

*   **Tool Center + Extended Tools**: Unified management for MCP, Shortcuts, built-in local tools, custom JavaScript tools, Agent Skills, and built-in tools like `getSystemTime`, grouped by source and use case with toggles, approval policies, session-level enablement, categorization, and tool detail pages.
*   **Agent Skills Packages**: Supports importing skill bundles from local folders, GitHub repository links, GitHub raw / nested directories, default branches, and hidden directories. Skill resources support text-encoding reads, large-file chunking, document text extraction, and image OCR. Once Agent mode and local Linux are enabled, a Skill may execute files under `scripts/` with explicit approval; the Skill is mounted read-only and its script version and hashes are frozen for the Run.
*   **Structured Q&A Tool (`ask_user_input`)**: Supports step-by-step single-question flow, single/multi choice exclusivity rules, custom input, and previous-question navigation.
*   **Custom JavaScript Tools**: Supports separated JS execution and AI-created script tools. Scripts live in a dedicated `CustomJSTools` directory, are validated before creation, and can be enabled, disabled, and assigned approval policies like regular tools.
*   **Extended Tooling Coverage**: Adds built-in system time, SQLite CRUD tools, web card display, input-box filling, sandbox file operations, and automatic feedback ticket submission.
*   **Sandbox File System Tools**: Supports search, chunked reading, diff viewing, partial edits, move / copy / delete, and other file operations.
*   **MCP Integration**: Built on the official Swift [Model Context Protocol](https://modelcontextprotocol.io) SDK, with streamable HTTP / SSE transport, reconnect handling, timeouts, handshake governance, metadata refresh, resource/template/prompt reads, and capability negotiation. Supports server drag ordering, tool-level enablement/approval policies, built-in server deletion and restore, and deferred auto-connect per chat-exposure toggle.
*   **Built-in MCP Servers**: Includes built-in search, local app tools, and personal-data MCP servers. The personal-data server requests HealthKit, Calendar, and Reminders permissions only when a tool is actually invoked.
*   **Siri Shortcuts**: Integrates with the Shortcuts framework, supports AI invocation through shortcuts, custom tools, and URL Scheme routing.
*   **In-App File Management**: Includes a built-in file manager for browsing and managing sandbox files directly inside the app, with inline preview for plain-text files.

#### Agents, Native Capabilities, and Local Linux

*   **Per-Session Chat / Agent Mode**: The mode is saved with each conversation. Chat never exposes Agent tools to the model. Agent mode can use Browser Agent, native capabilities, and conversation collaboration without Linux; command, Linux-file, and local stdio MCP capabilities are added only after local Linux is enabled. User terminals remain independently available in both modes.
*   **Built-In Local Linux**: `ish-multiarch` embeds a minimal Alpine AArch64 RootFS on both iOS and watchOS. The system is installed lazily only when an operation needs it. Enabling the setting does not start Linux, and the app never silently installs Python, Node.js, or build tools; optional environment recipes show the exact command, repository, and storage impact before the user runs them.
*   **Commands, PTY, and Task Governance**: Includes `linux_run`, `linux_shell`, `linux_process`, interactive PTY terminals, a task browser, paged output, cancellation, and diagnostics. User terminals, Agent commands, and Agent PTYs are isolated while sharing the authorized RootFS and workspace. stdout and stderr continue to drain in the background without requiring the chat view to remain open.
*   **Workspaces, Mounts, and Environment Variables**: Each conversation gets its own workspace. App storage, iCloud Drive, and explicitly authorized external folders can be mounted read-only or read-write. Environment variables live in GRDB and are injected when a process starts; model-, log-, and diagnostic-facing copies can redact sensitive values.
*   **Unified File Tools and Local MCP**: The existing file tools understand `app://`, `linux://`, and `mount://` instead of adding a separate Linux API that could bypass policy. Local stdio MCP shares the same management page, ordering, tool toggles, and approval rules as HTTP / SSE servers, with common `mcpServers` JSON import and export.
*   **Browser Agent**: The governed iOS WKWebView supports session-isolated tabs, DOM / accessibility snapshots, click, typing, scrolling, JavaScript, screenshots, downloads, and user takeover. watchOS probes actual local capabilities and can delegate missing operations to the paired iPhone when the user enables that relay.
*   **64 Apple-Native Tools**: Four groups cover device, media/environment, personal data, and vision/language capabilities: clipboard, notifications, AlarmKit, maps, device status, speech, media, WeatherKit, HomeKit, Bluetooth, NFC, contacts, photos, location, Vision, and NaturalLanguage. Tools report real platform/version availability, side effects require per-call approval, and selected watchOS gaps can be delegated to iPhone.
*   **Persistent Conversation Collaboration**: Agents can create hidden subagents or visible collaborative conversations, wait for results, deliver in the background, or continue the current conversation after completion. Results are scoped by session / run / tool so concurrent conversations cannot receive each other's output.
*   **Live Activities and Background Completion Notifications**: iOS displays Chat / Agent state on the Lock Screen and Dynamic Island, including running, waiting, completed, and failed states, with a deep link back to the source conversation. When the app moves to the background it uses the finite execution window granted by iOS to continue a reply or Linux task; a local notification is posted only if the reply actually finishes in the background, and system suspension is recorded as an interruption rather than silently replayed.

#### Memory and Knowledge Organization

*   **Local RAG Memory**: Embeddings can use cloud APIs or registered local embedding models, while the **vector database itself runs fully locally on SQLite**. Also supports chunking, embedding progress visualization, memory editing, per-memory re-embedding, retrieval timestamp controls, and active retrieval tools.
*   **GRDB Relational Persistence**: Core persistence migrated from JSON to GRDB + SQLite, covering sessions, configuration, MCP, worldbooks, memory, feedback, shortcuts, usage analytics, and global prompts; SQLCipher full-disk physical encryption can be turned on as a base layer.
*   **Worldbook**: A Lorebook-style system similar to SillyTavern, with background setting management, conditional triggers, session-bound isolation, system injection, and URL import. SillyTavern compatibility has been further improved for multi-book injection, injection-budget control, and field isolation.
*   **Broad Format Compatibility**: Compatible with PNG naidata, top-level JSON arrays, and `character_book` worldbook formats.
*   **Request Logs and Speed Insights**: Includes independent request logs, payload detail pages, an optional toggle for plain-text request message logging, detailed token summaries, and streaming-response speed charts.
*   **Usage Analytics**: Tracks text requests, model rankings, tokens, and cached tokens. Provides iOS/watchOS dashboards, a green heatmap, cache-hit rate, and cross-device sync; today's trend is split by hour, and per-model token trend charts, share analysis, and an all-time range are available.
*   **Advanced Rendering**: Built-in Markdown rendering with syntax highlighting, tables, and LaTeX math support.

#### Daily Pulse Proactive Briefing

*   **Daily Pulse**: Generates proactive cards every day so the app can surface what might be worth your attention before you even ask.
*   **Pulse Task Workflow**: Cards can be turned into follow-up tasks. Incomplete tasks persist across days and feed into the next Pulse run.
*   **Feedback History Learning**: Likes, downranks, hides, and saves become long-term preference signals that keep shaping future results.
*   **Morning Reminders and Continue Chat**: Supports scheduled reminders, notification quick actions, saving cards as sessions, and continuing into chat flows on both iOS and watchOS.

#### Security, Sync, and Operations

*   **App Lock**: Two-factor protection backed by a Keychain-stored PBKDF2 master password and biometrics (Face ID / Touch ID); supports verifying the old password when changing it and auto-presenting the unlock screen on lock. Available on both iOS and watchOS.
*   **Full-Disk Database Encryption**: SQLCipher applies physical-layer encryption to the core SQLite databases, with encrypted migration, new-password verification, and reads from encrypted side-databases. The in-app file browser and debug tools are fully compatible.
*   **Snapshot Backup and Encryption**: Builds offline database snapshots through the SQLite Online Backup API (with FTS stripping), supports a full snapshot mode, and offers dual-mode AES-256-GCM encryption (simple password / PBKDF2), along with binary `.elsbackup` upload and a secure restore flow.
*   **Cross-Device Sync**: A built-in iOS ↔ watchOS sync engine that automatically syncs provider config, sessions, session tags, worldbooks, tool settings, Daily Pulse, usage analytics, user profile, global prompts, and more. Supports Manifest/Delta differential sync, a WatchConnectivity fast channel, iCloud roaming sync, offline session-fork isolation, and merging of retry-version history for the same message.
*   **Multi-Channel Cloud Backup**: Supports ETOS package export/import, `.elsbackup` snapshot import, full import on watchOS, CloudKit transport (including APNs silent push to trigger background sync), iCloud Drive backup export/import, startup backup with corruption self-healing, and signed snapshot uploads to S3-compatible object storage (AWS S3 / Cloudflare R2), remote snapshot browsing, plus restore by downloading from the cloud.
*   **AppConfigStore Configuration Hub**: Fully replaces `@AppStorage`; every runtime setting goes through GRDB persistence with a runtime read cache and background async writes dispatched back to the main thread, avoiding main-thread I/O and multi-device config drift. A one-time migration from legacy UserDefaults is included.
*   **Update Timeline**: A back-end-free version tracking system that rebuilds the release timeline locally from build info and cache, with AI summaries rendered as Markdown — iOS shows it in batches, watchOS splits it into a second-level browser.
*   **In-App Feedback Assistant**: Supports feedback categories, environment collection, Git commit hash, PoW submission flow, in-ticket comments, jumping from referenced commits into the update timeline, distribution-channel display, and cross-device sync.
*   **Network Proxy Support**: Supports global and provider-level HTTP(S)/SOCKS proxy with authentication.
*   **Feedback Center and Notifications**: Supports in-ticket comments, developer badge display, status auto-refresh, and high-priority local notifications with deep links.
*   **LAN Debugging**: Includes a LAN debugging client, a Go-based TUI debugging tool, and a built-in web console; supports Bonjour discovery, file / SQLite / Provider / advanced model configuration / MCP management, app configuration editing, and OpenAI request capture.
*   **Doc Site**: A new VitePress documentation site covering installation, first chat, provider setup, UI tours, module references, design docs, and usage tips.
*   **Localization**: Supports 8 languages — English, Simplified Chinese, Traditional Chinese (Hong Kong), Japanese, Russian, French, Spanish, and Arabic, with in-app language switching.

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

*   **Language**: Swift 6, C / C++ (public llama.cpp and iSH bridge layers)
*   **UI**: SwiftUI
*   **Architecture**: MVVM + Protocol Oriented Programming
*   **Data**: GRDB + SQLite + SQLCipher (core persistence, local vector store, and optional full-disk physical encryption), JSON (import/export and compatibility formats)
*   **Configuration**: AppConfigStore (replaces `@AppStorage`; GRDB-backed persistence + runtime cache + background async writes)
*   **Security**: SQLCipher full-disk encryption, Keychain PBKDF2 master password, LocalAuthentication biometrics, AES-256-GCM snapshot encryption
*   **Networking and Transport**: URLSession (API requests), Streamable HTTP / SSE (MCP transport), WatchConnectivity / CloudKit / APNs silent push (cross-device and cloud transport), WebSocket / HTTP polling (LAN debugging)
*   **AI Protocol**: Model Context Protocol (built on the official [swift-sdk](https://github.com/modelcontextprotocol/swift-sdk)), OpenAI Chat / Responses, Anthropic Messages, Gemini API, local `local-llama-cpp` provider
*   **Local Inference**: llama.cpp / GGUF, Swift ↔ C ABI ↔ C++ bridge, CMake + Ninja-prebuilt `libetos-llama.a`, Accelerate / Metal (watchOS runtime stays on the CPU path)
*   **Local Agent Runtime**: `ish-multiarch`, bundled Alpine AArch64 RootFS, Meson + Ninja-prebuilt `libiSHApple.a`, PTY, dynamic mounts, guest file APIs, and local stdio MCP
*   **Agent Capabilities**: 64 Apple-native MCP tools, WKWebView Browser Agent, executable Agent Skills, persistent conversation collaboration, and a permission context frozen per Run
*   **System Integrations**: Siri Shortcuts, WatchConnectivity, CloudKit, UserNotifications, ActivityKit / WidgetKit, finite iOS background tasks, LocalAuthentication, Speech / AVFoundation
*   **Doc Site**: VitePress / Teek (doc site only; its dependencies are not counted in the code-size figures above)
*   **Dependency Management**: Swift Package Manager (current explicit dependencies: `GRDB.swift` (Eric-Terminal fork), `SQLCipher.swift`, `swift-sdk` (MCP), `swift-markdown-ui`, `SwiftMath`, `ZIPFoundation`, `Cepheus` (watchOS third-party keyboard), with transitive dependencies such as `networkimage`, `swift-cmark`, `eventsource`, `swift-nio`) + llama.cpp / ish-multiarch Git submodules + separate static-library build scripts

---

## 🏗️ Project Architecture

The project uses a two-layer structure: a platform-independent ETOSCore framework plus platform-specific view layers. Chat, Agent orchestration, native tools, Browser Agent, local Linux, MCP, and Skills all enter the same ETOSCore runtime context, approval, audit, and persistence boundaries before iOS and watchOS provide their platform-specific interfaces and system integrations.

```
ETOSCore/ETOSCore/                         ← Platform-agnostic business logic (481 Swift source files)
├── AppTool/                            ← Local tools, custom JS tools, ask_user_input, SQLite and sandbox file tools
├── Attachments/                        ← File attachment text extraction
├── BrowserAgent/                       ← Governed browser sessions, DOM automation, capture, download, cookies, iPhone relay
├── Chat/                               ← Chat models, message versions, export, render state
│   ├── ConversationRuntime/            ← Persistent collaboration, subagents, wait graph, budgets, and continuations
│   └── Service/                        ← ChatService request orchestration, response parsing, retry, tools, memory & worldbook injection
├── Config/                             ← AppConfigStore hub, key definitions, and legacy UserDefaults migration
├── ConfigLoader/                       ← Provider config, SQLite storage, background and one-shot download state
├── Core/                               ← Core models, JSONValue, request-body controls and shared infrastructure
├── DailyPulse/                         ← Daily Pulse generation, filtering, delivery, feedback, and task data
├── Feedback/                           ← In-app feedback assistant, environment collection, DTOs, and local storage
├── Font/                               ← Custom font library, font routing, and fallback scopes
├── LocalDebugServer/                   ← LAN debugging client, web console, file / SQLite / Provider commands, and request capture
├── LocalAgentRuntime/                  ← Local Linux, RootFS, PTY, workspace, mounts, tasks, approvals, and iSH C ABI
├── LocalLLM/                            ← Local GGUF model records, provider bridge, parameter mapping, and Swift inference entry point
├── LocalLLMBridge/                      ← llama.cpp C ABI / C++ bridge layer and static-library link boundary
├── Math/                               ← LaTeX / math formula rendering engine
├── MCP/                                ← MCP client, built-in servers, server storage, Streamable HTTP / SSE transport (built on the official swift-sdk)
├── Memory/ + SimilaritySearch/         ← Local RAG, embedding, chunking, SQLite vector retrieval
├── NativeCapabilities/                 ← Definitions, executors, permissions, and cross-device relay for 64 Apple-native tools
├── Parsing/                            ← Request-header and parameter-expression parsers
├── Persistence/                        ← GRDB main/auxiliary databases, migrations, startup backup, media and file storage
├── Providers/                          ← Provider models, proxy configuration, and OpenAI / Anthropic / Gemini adapters
├── Roleplay/                           ← Roleplay personas, chat prompt templates, and preset character library
├── Security/                           ← App lock state machine, PBKDF2 master password, and database encryption manager
├── Shortcuts/                          ← Siri Shortcuts, URL router, import and execution relays
├── Skills/                             ← Agent Skills import, resource reads, script snapshots, approval, and local Linux execution
├── Snapshot/                           ← Offline database snapshot builder, AES-256-GCM encryption, and secure restore
├── Storage/                            ← Sandbox file browsing, storage statistics, cache cleanup
├── Sync/                               ← WatchConnectivity fast channel / CloudKit / iCloud roaming / Manifest / Delta / iCloud Drive / S3 and third-party imports
├── System/                             ← Global prompts, notifications, announcements, logging, speech recognition, OCR, update timeline
├── TTS/                                ← System / cloud text-to-speech, queued playback, configuration, and presets
├── UI/                                 ← Cross-platform UI components (app-lock views, marquee text, etc.)
├── UsageAnalytics/                     ← Usage events, dashboards, per-hour trends, and per-model token share
└── Worldbook/                          ← Worldbook models, import/export, SQLite storage, and trigger engine

ETOS LLM Studio/ETOS LLM Studio iOS App/    ← iOS view layer (187 Swift source files)
ETOS LLM Studio/ETOS LLM Studio Watch App/  ← watchOS view layer (156 Swift source files)
ETOS LLM Studio/ETOS Agent Widgets/          ← iOS widgets and Live Activity
ETOS LLM Studio/ETOS Agent Watch Widgets/    ← watchOS widgets
ETOS LLM Studio/ETOS Workspace Provider/     ← Files / File Provider system entry
ETOS LLM Studio/ETOS Agent Share/            ← Share extension system entry
ETOSCore/ETOSCoreTests/                       ← ETOSCore-layer tests (147 Swift source files)
```

Cloud-model data flow: `View → ChatViewModel → ChatService.shared → Provider Adapter → LLM API`. Local-model data flow: `View → ChatViewModel → ChatService.shared → LocalLLMEngine → LocalLLMBridge → libetos-llama.a / llama.cpp`. Agent-tool data flow: `ChatService → AgentRuntimeContext → approval and audit → BrowserAgent / NativeCapabilities / MCP / Skills / LocalAgentRuntime → libiSHApple.a`. Sessions, Runs, tools, memory, worldbooks, usage analytics, and sync data are all governed through ETOSCore services and GRDB / SQLite.

---

## 🚀 Build Guide

If you want to build it yourself:

1.  **Clone the project and submodules**:
    ```bash
    git clone --recurse-submodules https://github.com/Eric-Terminal/ETOS-LLM-Studio.git
    cd ETOS-LLM-Studio
    ```
    If the repository was cloned earlier and either `Dependencies/llama.cpp` or `Dependencies/ish-multiarch` is missing, run:
    ```bash
    git submodule update --init --recursive
    ```
2.  **Requirements**:
    *   Xcode 26.0+
    *   watchOS 26.0+ SDK
    *   CMake + Ninja for llama.cpp
    *   Meson + Ninja for iSHApple
    *   Recommended installation: `brew install cmake ninja meson`
    *   (If your environment does not match exactly, you can adjust compatibility yourself.)
3.  **Generate the native static libraries before building**:
    Xcode does not repeatedly compile llama.cpp and iSH in a normal Build Phase. The unified entry calls the two dedicated build scripts and stages two independent archives in the same Xcode library search directory; it never merges them into one `.a` file.

    For device / Release builds:
    ```bash
    CONFIGURATION=Release SDK_NAME=iphoneos PLATFORM_NAME=iphoneos ARCHS=arm64 scripts/build-native-static-libraries.sh --parallel
    CONFIGURATION=Release SDK_NAME=watchos PLATFORM_NAME=watchos ARCHS="arm64 arm64_32" scripts/build-native-static-libraries.sh --parallel
    ```
    For the iOS + watchOS Debug simulators used by this README:
    ```bash
    CONFIGURATION=Debug SDK_NAME=iphonesimulator PLATFORM_NAME=iphonesimulator ARCHS=arm64 scripts/build-native-static-libraries.sh --parallel
    CONFIGURATION=Debug SDK_NAME=watchsimulator PLATFORM_NAME=watchsimulator ARCHS=arm64 scripts/build-native-static-libraries.sh --parallel
    ```
    The first invocation builds the iSHApple device and simulator slices for iOS and watchOS plus the llama.cpp product requested by the current command, so it is much slower than a cached build. Each dependency validates its own cache: changing iSH does not rebuild llama.cpp, and vice versa. `--parallel` passes the local CPU count to CMake by default; `--parallel=8`, `--jobs 8`, and `-j8` select an explicit task count.

    Main outputs:

    | Artifact | Location | Purpose |
    | --- | --- | --- |
    | `iSHApple.xcframework` | `Dependencies/ish-build/iSHApple.xcframework` | Public multi-platform iSH artifact |
    | `libiSHApple.a` | `Dependencies/ish-build/products/<platform>/` | Original per-platform iSH archive |
    | `libetos-llama.a` | `Dependencies/llama-build/products/<platform>-<configuration>/` | llama.cpp / ggml / mtmd |
    | Staged `libiSHApple.a` | Next to `libetos-llama.a` | Found and linked for the current Xcode SDK / Configuration |

    ETOSCore links llama.cpp with `-letos-llama`. The iOS / watchOS Linux adapter carries a separate `-liSHApple` object linker option, so Xcode consumes both archives directly. Generated directories are ignored by Git and should never be committed.
4.  **Open the project**:
    Open `ETOS LLM Studio.xcworkspace` (**workspace**, not xcodeproj).
    On first launch, Xcode will automatically resolve and fetch Swift Package dependencies.
5.  **Run**:
    Select the `ETOS LLM Studio App` scheme to run the iOS app; choose the `ETOS LLM Studio Watch App` scheme only when debugging watchOS directly. Connect a device (or simulator), then press Command + R.
6.  **Configure**:
    After launching, add your API key in Settings. I strongly recommend using the “LAN Debugging” feature to push prepared JSON configuration files straight into `Documents/Providers/` (because who really wants to type an API key on an Apple Watch?).

### Common Build Problems

*   `ish-multiarch submodule is not initialized`: run `git submodule update --init --recursive`.
*   Missing `meson`, `ninja`, or `cmake`: run `brew install cmake ninja meson`, then rerun the native-library script.
*   `library 'etos-llama' not found` or `library 'iSHApple' not found`: make sure the script's `SDK_NAME`, `PLATFORM_NAME`, and `CONFIGURATION` match the current Xcode destination.
*   Missing architecture during a watchOS device archive: regenerate the `watchos` Release product with `ARCHS="arm64 arm64_32"`.
*   watchOS linker failures caused by inherited shell variables: use the `env -u ... xcodebuild` commands in the next section.

---

## 🧪 Automated Testing and Build

To build or run tests from the command line, use the standard `xcodebuild` commands below (with environment variables cleared to prevent build failures):

* **Build iOS App (includes embedded watch App)**:
  ```bash
  env -u SDKROOT -u LIBRARY_PATH -u CPATH -u C_INCLUDE_PATH -u CPLUS_INCLUDE_PATH -u OBJC_INCLUDE_PATH xcodebuild -workspace 'ETOS LLM Studio.xcworkspace' -scheme 'ETOS LLM Studio App' -destination 'platform=iOS Simulator,name=iPhone 17 Pro,OS=26.5' build
  ```
* **Verify watchOS App Build**:
  ```bash
  env -u SDKROOT -u LIBRARY_PATH -u CPATH -u C_INCLUDE_PATH -u CPLUS_INCLUDE_PATH -u OBJC_INCLUDE_PATH xcodebuild -workspace 'ETOS LLM Studio.xcworkspace' -scheme 'ETOS LLM Studio Watch App' -destination 'generic/platform=watchOS Simulator' build
  ```
* **Run ETOSCore Framework Tests** (147 test files, 50,853 lines of test code):
  ```bash
  env -u SDKROOT -u LIBRARY_PATH -u CPATH -u C_INCLUDE_PATH -u CPLUS_INCLUDE_PATH -u OBJC_INCLUDE_PATH xcodebuild -workspace 'ETOS LLM Studio.xcworkspace' -scheme 'ETOSCore' -destination 'platform=iOS Simulator,name=iPhone 17 Pro,OS=26.5' -parallel-testing-enabled NO test
  ```
* **Run iOS App Unit & UI Tests**:
  ```bash
  env -u SDKROOT -u LIBRARY_PATH -u CPATH -u C_INCLUDE_PATH -u CPLUS_INCLUDE_PATH -u OBJC_INCLUDE_PATH xcodebuild -workspace 'ETOS LLM Studio.xcworkspace' -scheme 'ETOS LLM Studio App' -destination 'platform=iOS Simulator,name=iPhone 17 Pro,OS=26.5' -parallel-testing-enabled NO test
  ```
* **Run watchOS App Unit & UI Tests**:
  ```bash
  env -u SDKROOT -u LIBRARY_PATH -u CPATH -u C_INCLUDE_PATH -u CPLUS_INCLUDE_PATH -u OBJC_INCLUDE_PATH xcodebuild -workspace 'ETOS LLM Studio.xcworkspace' -scheme 'ETOS LLM Studio Watch App' -destination 'platform=watchOS Simulator,name=Apple Watch Series 11 (46mm),OS=26.5' -parallel-testing-enabled NO test
  ```

---

## 📬 Contact

*   **Developer**: Eric Terminal
*   **Email**: ericterminal@ericterminal.com
*   **GitHub**: [Eric-Terminal](https://github.com/Eric-Terminal)

---

This README was last revised on August 12, 2026. The project moves quickly, so if the README falls behind the code, the commit history is the best source of truth.
