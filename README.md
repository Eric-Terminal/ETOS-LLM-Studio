# ETOS LLM Studio

![Swift](https://img.shields.io/badge/Swift-FA7343?style=flat-square&logo=swift&logoColor=white)
![Platform](https://img.shields.io/badge/Platform-iOS%20%7C%20watchOS-blue?style=flat-square&logo=apple&logoColor=white)
![License](https://img.shields.io/badge/License-GPLv3-0052CC?style=flat-square)
![Build](https://img.shields.io/badge/Build-Passing-44CC11?style=flat-square)

**一个运行在 iOS 和 Apple Watch 上的原生 AI 客户端。**

[English](docs/readme/README_EN.md) | [繁體中文](docs/readme/README_ZH_HANT.md) | [日本語](docs/readme/README_JA.md)

---

## 📸 截图

| | |
|:---:|:---:|
| <img src="assets/screenshots/screenshot-01.png" width="300"> | <img src="assets/screenshots/screenshot-02.png" width="300"> |
| <img src="assets/screenshots/screenshot-03.png" width="300"> | <img src="assets/screenshots/screenshot-04.png" width="300"> |
| <img src="assets/screenshots/screenshot-05.png" width="300"> | <img src="assets/screenshots/screenshot-06.png" width="300"> |

---

## 👋 写在前面

在学校的日子挺无聊的，平时又有很多问题想问问 AI。
当时嫌 App Store 上的 AI 应用要么贵得离谱，要么功能太残废（尤其是手表端），索性就自己动手搓了一个。

从最初那个只有 1,800 行代码、API Key 还要硬编码的简陋版本，到现在快 20,000 行代码、结构稍微像样点的工程，它确实成长了不少。虽然名字叫 "ETOS LLM Studio" 听着挺唬人，但它本质上就是我探索大模型应用边界的一个试验场。

现在，它已经不再仅仅是一个手表端的 App，我也顺手把 iOS 端的全功能版本也给做上了，这样在手机上管理配置和聊天也会舒服得多。

不过因为我家人不太允许我使用手机的问题，我一般只用Mac和Watch，导致手机。。。可能体验有点一言难尽，但是我会尽力优化的，我的电脑模拟器跑iPhone真的很吃力。

### 主要功能
*   **双端原生体验**：iOS 和 Apple Watch 原生适配。虽然手表端是核心，但手机端现在也同样好用(吧？)。
*   **动态配置**：早已告别了改 Key 要重新编译的石器时代。现在支持在 App 内动态管理配置，原生适配了 OpenAI、Anthropic (Claude) 和 Google (Gemini) 的 API 格式。
*   **本地 RAG (记忆)**：虽然 Embedding 需要调用云端 API(Apple本地的端侧小模型太颠了)，但**向量数据库是完全运行在本地的 (SQLite)**。你的长期记忆数据掌握在自己手里，而不是在云端。
*   **MCP 支持**：支持远程 Model Context Protocol，AI 可以调用一些简单的内置工具。本地因为系统的沙盒限制做不到。
*   **多模态**：支持发送语音和图片。
*   **局域网调试**：为了方便把配置文件塞进沙盒，我内置了一个 HTTP 客户端。配合专用程序，你可以在电脑浏览器里直接管理应用内的文件，或者查看实时调试日志。

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

*   **语言**: Swift
*   **UI**: SwiftUI
*   **架构**: MVVM + Protocol Oriented Programming
*   **数据**: SQLite (本地向量库), JSON (配置持久化)
*   **网络**: URLSession, NWConnection (WebSocket调试)

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
    *   (如果对不上你可以自己改一改兼容性)
3.  **运行**:
    打开项目，选择 `ETOS LLM Studio Watch App` Target，连上手表（或模拟器），Command + R 即可。
4.  **配置**:
    启动后，去设置里添加你的 API Key。推荐使用“局域网调试”功能，直接把做好的 JSON 配置文件推送到 `Documents/Providers/` 目录下(真的有人会想在Apple Watch上面戳API key进去吗)。

---

## 📬 联系方式

*   **开发者**: Eric Terminal
*   **Email**: ericterminal@gmail.com
*   **GitHub**: [Eric-Terminal](https://github.com/Eric-Terminal)

---

本次README修订与2025年1月11日，217c080之后，软件更新可能很勤快README可能更新不及时
