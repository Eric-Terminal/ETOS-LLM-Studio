# ETOS LLM Studio

![Swift](https://img.shields.io/badge/Swift-FA7343?style=flat-square&logo=swift&logoColor=white)
![Platform](https://img.shields.io/badge/Platform-iOS%20%7C%20watchOS-blue?style=flat-square&logo=apple&logoColor=white)
![License](https://img.shields.io/badge/License-GPLv3-0052CC?style=flat-square)
![Build](https://img.shields.io/badge/Build-Passing-44CC11?style=flat-square)

**一个运行在 iOS 和 Apple Watch 上的原生 AI 客户端。支持 OpenAI、Anthropic Claude、Google Gemini 等多个大模型提供商，内置本地 RAG 记忆、MCP 工具调用、世界书、Siri 快捷指令等进阶功能。**

[English](docs/readme/README_EN.md) | [繁體中文](docs/readme/README_ZH_HANT.md) | [日本語](docs/readme/README_JA.md)

---

## 📸 截图

| | |
|:---:|:---:|
| <img src="assets/screenshots/screenshot-01.png" width="300"> | <img src="assets/screenshots/screenshot-02.png" width="300"> |

---

## 👋 写在前面

在学校的日子挺无聊的，平时又有很多问题想问问 AI。
当时嫌 App Store 上的 AI 应用要么贵得离谱，要么功能太残废（尤其是手表端），索性就自己动手搓了一个。

从最初那个只有 1,800 行代码、API Key 还要硬编码的简陋版本，到现在 130 个源文件、超过 50,000 行代码的工程，它确实成长了不少。虽然名字叫 "ETOS LLM Studio" 听着挺唬人，但它本质上就是我探索大模型应用边界的一个试验场。

现在，它已经不再仅仅是一个手表端的 App，我也顺手把 iOS 端的全功能版本也给做上了，这样在手机上管理配置和聊天也会舒服得多。两端的数据还能通过内置的同步引擎自动互通。

不过因为我家人不太允许我使用手机的问题，我一般只用Mac和Watch，导致手机。。。可能体验有点一言难尽，但是我会尽力优化的，我的电脑模拟器跑iPhone真的很吃力。

### 主要功能

*   **双端原生体验**：iOS 和 Apple Watch 原生适配，两端视图高度对称，UI 各自针对屏幕尺寸优化。虽然手表端是核心，但手机端现在也同样好用(吧？)。
*   **多模型支持**：原生适配 OpenAI、Anthropic (Claude) 和 Google (Gemini) 的 API 格式，支持在 App 内动态管理提供商和模型配置，还支持自定义请求头和参数表达式。
*   **本地 RAG (记忆)**：虽然 Embedding 需要调用云端 API（Apple 本地的端侧小模型太颠了），但**向量数据库是完全运行在本地的 (SQLite)**。你的长期记忆数据掌握在自己手里，而不是在云端。支持文本分块、嵌入进度可视化和记忆编辑。
*   **MCP 工具调用**：支持远程 [Model Context Protocol](https://modelcontextprotocol.io)，包含完整的 MCP 客户端、流式 HTTP 传输和服务器配置管理。采用懒连接机制，首次调用时自动初始化。本地因为系统的沙盒限制做不到。
*   **世界书 (Worldbook)**：类似 SillyTavern 的 Lorebook 系统，支持角色背景设定的管理、编辑和条件触发。兼容多种导入格式（PNG naidata、JSON 顶层数组、character_book），iOS 和 watchOS 双端同步。
*   **Siri 快捷指令**：集成 Shortcuts 框架，支持通过快捷指令调用 AI 能力，可自定义工具并通过 URL Scheme 路由。
*   **多模态**：支持发送语音和图片，支持 AI 图像生成。
*   **跨端同步**：内置 iOS ↔ watchOS 同步引擎，提供商配置、会话、世界书等数据自动互通。
*   **高级渲染**：内置 Markdown 渲染器，支持代码高亮、表格和 LaTeX 数学公式。
*   **局域网调试**：内置 HTTP 客户端，配合专用程序可在电脑浏览器里直接管理应用内文件或查看实时调试日志。
*   **本地化**：支持英语、简体中文、繁体中文（香港）和日语四种语言。

---

## 💸 关于收费与开源

说实话，我最开始是想做免费软件的。
但 Apple Developer Program 每年 $99 的费用，对我一个学生来说确实有点吃力。

后来有位投资人帮我垫付了这笔钱，代价是我需要通过软件收费来偿还这笔投资（而且还要分成给他）。所以 App Store 版本象征性地收了一点费用，这就当是大家众筹帮我还债，顺便买个“不用每七天重签一次”的便利服务。

**但是，开源是我的底线。**

所以现在的规则很简单：
1.  **想省事/支持我**：App Store 见，感谢你的“可乐钱”。
2.  **想折腾/白嫖**：代码就在这儿，GPLv3 协议。如果你有 Mac 和 Xcode，**完全可以自己编译安装，功能上没有任何区别**。

技术本该共享，我不希望因为几十块钱的门槛，挡住了同样对代码感兴趣的你。

---

## 🛠️ 技术栈

*   **语言**: Swift 6
*   **UI**: SwiftUI
*   **架构**: MVVM + Protocol Oriented Programming
*   **数据**: SQLite (本地向量数据库), JSON (配置持久化)
*   **网络**: URLSession (API 请求), Streamable HTTP (MCP 传输)
*   **AI 协议**: Model Context Protocol (MCP)
*   **集成**: Siri Shortcuts, WatchConnectivity (跨端同步)
*   **无第三方依赖**：项目完全自包含，不依赖 SPM / CocoaPods 等包管理器

---

## 🏗️ 项目架构

项目采用双层结构：平台无关的 Shared 框架 + 各平台独立的视图层。

```
Shared/Shared/                  ← 平台无关的业务逻辑（框架，50 个源文件）
├── ChatService.swift            ← 中央单例，管理会话/消息/模型选择/网络请求
├── APIAdapter.swift             ← API 适配层（OpenAI / Anthropic / Gemini）
├── Models.swift                 ← 核心数据模型
├── Persistence.swift            ← 数据持久化
├── MemoryManager.swift          ← RAG 记忆管理
├── Memory/                      ← 记忆子系统（分块、嵌入、存储）
├── SimilaritySearch/            ← 本地向量数据库（SQLite）
├── MCP/                         ← Model Context Protocol 客户端与传输层
├── Worldbook/                   ← 世界书引擎、导入导出
├── Sync/                        ← iOS ↔ watchOS 同步引擎
├── Shortcuts/                   ← Siri Shortcuts 集成
└── LocalDebugServer.swift       ← 局域网 HTTP 调试客户端

ETOS LLM Studio Watch App/      ← watchOS 视图层（32 个视图文件）
ETOS LLM Studio iOS App/        ← iOS 视图层（30 个视图文件）
```

数据流：`View → ChatViewModel → ChatService.shared → APIAdapter → LLM API`，通过 Combine Subjects 驱动 UI 更新。

---

## 🚀 编译指南

如果你决定自己动手：

1.  **Clone 项目**:
    ```bash
    git clone https://github.com/Eric-Terminal/ETOS-LLM-Studio.git
    ```
2.  **环境要求**:
    *   Xcode 26.0+
    *   watchOS 26.0+ SDK
    *   （如果对不上你可以自己改一改兼容性）
3.  **打开项目**:
    打开 `ETOS LLM Studio.xcworkspace`（注意是 **workspace** 不是 xcodeproj）。
4.  **运行**:
    选择 `ETOS LLM Studio Watch App` 或 `ETOS LLM Studio iOS App` Target，连上设备（或模拟器），Command + R 即可。
5.  **配置**:
    启动后，去设置里添加你的 API Key。推荐使用"局域网调试"功能，直接把做好的 JSON 配置文件推送到 `Documents/Providers/` 目录下（真的有人会想在 Apple Watch 上面戳 API Key 进去吗）。

---

## 📬 联系方式

*   **开发者**: Eric Terminal
*   **Email**: ericterminal@gmail.com
*   **GitHub**: [Eric-Terminal](https://github.com/Eric-Terminal)

---

本次 README 修订于 2026 年 2 月 11 日（bf5e0ee），软件更新可能很勤快，README 可能更新不及时
