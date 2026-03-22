# ETOS LLM Studio

![Swift](https://img.shields.io/badge/Swift-FA7343?style=flat-square&logo=swift&logoColor=white)
![Platform](https://img.shields.io/badge/Platform-iOS%20%7C%20watchOS-blue?style=flat-square&logo=apple&logoColor=white)
![License](https://img.shields.io/badge/License-GPLv3-0052CC?style=flat-square)
![Build](https://img.shields.io/badge/Build-Passing-44CC11?style=flat-square)

**一個運行在 iOS 和 Apple Watch 上的原生 AI 客戶端。支持 OpenAI、Anthropic Claude、Google Gemini 等多個大模型提供商，內置本地 RAG 記憶、MCP 工具調用、世界書、Siri 捷徑等進階功能。**

[簡體中文](../../README.md) | [English](README_EN.md) | [Japanese](README_JA.md)

---

## 📸 截圖

| | |
|:---:|:---:|
| <img src="../../assets/screenshots/screenshot-01.png" width="300"> | <img src="../../assets/screenshots/screenshot-02.png" width="300"> |

---

## 👋 寫在前面

在學校的日子挺無聊的，平時又有很多問題想問問 AI。
當時嫌 App Store 上的 AI 應用要麼貴得離譜，要麼功能太殘廢（尤其是手錶端），索性就自己動手搓了一個。

從最初那個只有 1,800 行代碼、API Key 還要硬編碼的簡陋版本，到現在 155 個 Swift 源文件、超過 73,000 行代碼（含 Shared/iOS/watchOS 與測試代碼）的工程，它確實成長了不少。雖然名字叫 "ETOS LLM Studio" 聽著挺唬人，但它本質上就是我探索大模型應用邊界的一個試驗場。

現在，它已經不再僅僅是一個手錶端的 App，我也順手把 iOS 端的全功能版本也給做上了，這樣在手機上管理配置和聊天也會舒服得多。

不過因為我家人不太允許我使用手機的問題，我一般只用 Mac 和 Watch，導致手機。。。可能體驗有點一言難盡，但我會盡力優化的，我的電腦模擬器跑 iPhone 真的很吃力。

### 主要功能
*   **雙端原生體驗**：iOS 和 Apple Watch 原生適配，並針對各自屏幕尺寸做了 UI 優化。
*   **多模型支持**：原生適配 OpenAI、Anthropic (Claude) 和 Google (Gemini) 的 API 格式，支持在 App 內動態管理提供商與模型配置，並支持自定義請求頭、參數表達式、原始 JSON 請求體。
*   **工具中心 + 拓展工具**：統一管理 MCP / Shortcuts / 本地工具三類能力，支持聊天工具開關、審批策略、會話級啟用，並新增沙盒文件系統工具（搜尋、分塊讀取、差異查看、局部編輯、移動/複製/刪除等）。
*   **本地 RAG (記憶)**：雖然 Embedding 需要調用雲端 API（Apple 本地端側小模型太不穩定），但**向量數據庫完全運行在本地 (SQLite)**。支持文本分塊、嵌入進度可視化、記憶編輯與主動記憶檢索工具。
*   **MCP 工具調用**：支持遠程 [Model Context Protocol](https://modelcontextprotocol.io)，包含完整 MCP 客戶端、流式 HTTP/SSE 傳輸、服務器配置管理與更完整的協議兼容處理（重連、超時、握手治理、能力協商等）。
*   **世界書 (Worldbook)**：類似 SillyTavern 的 Lorebook 系統，支持背景設定管理、編輯與條件觸發；支持會話綁定隔離發送、system 注入、URL 導入，兼容 PNG naidata / JSON 頂層陣列 / character_book。
*   **請求日誌與測速分析**：內置獨立請求日誌、細分 Token 匯總，並提供流式響應速度統計與詳情圖表。
*   **存儲管理升級**：內置可瀏覽目錄的文件管理器，支持在 App 內查看與管理沙盒文件。
*   **Siri 捷徑**：集成 Shortcuts 框架，支持通過捷徑調用 AI 能力，可自定義工具並通過 URL Scheme 路由。
*   **應用內反饋助手**：支持反饋分類、環境信息採集、PoW 提交鏈路與雙端同步。
*   **多模態**：支持發送語音和圖片，支持 AI 圖像生成。
*   **跨端同步**：內置 iOS ↔ watchOS 同步引擎，提供商配置、會話、世界書、工具配置等數據自動互通。
*   **高級渲染**：內置 Markdown 渲染器，支持代碼高亮、表格與 LaTeX 數學公式。
*   **局域網調試**：內置 HTTP 客戶端，配合專用程序可在電腦瀏覽器中直接管理應用內文件或查看實時調試日誌。
*   **本地化**：支持英語、簡體中文、繁體中文（香港）、日語與俄語五種語言。

---

## 💸 關於收費與開源

說實話，我最開始是想做免費軟件的。
但 Apple Developer Program 每年 $99 的費用，對我一個學生來說確實有點吃力。

後來有位投資員幫我墊付了這筆錢，代價是我需要通過軟件收費來償還這筆投資（而且還要分成給他）。所以 App Store 版本象徵性地收了一點費用，這就當是大家眾籌幫我還債，順便買個「不用每七天重簽一次」的便利服務。

**但是，開源是我的底線。**

所以現在的規則很簡單：
1.  **想省事/支持我**：App Store 見，感謝你的「可樂錢」。
2.  **想折騰/白嫖**：代碼就在這兒，GPLv3 協議。如果你有 Mac 和 Xcode，**完全可以自己編譯安裝，功能上沒有任何區別**。

技術本該共享，我不希望因為幾十塊錢的門檻，擋住了同樣對代碼感興趣的你。

---

## 🛠️ 技術棧

*   **語言**: Swift 6
*   **UI**: SwiftUI
*   **架構**: MVVM + Protocol Oriented Programming
*   **數據**: SQLite (本地向量庫), JSON (配置持久化)
*   **網絡**: URLSession (API 請求), Streamable HTTP/SSE (MCP 傳輸)
*   **AI 協議**: Model Context Protocol (MCP)
*   **集成**: Siri Shortcuts, WatchConnectivity (跨端同步)
*   **依賴管理**: Swift Package Manager（當前顯式依賴 `swift-markdown-ui`，並包含其傳遞依賴 `networkimage`、`swift-cmark`）

---

## 🚀 編譯指南

如果你決定自己動手：

1.  **Clone 項目**:
    ```bash
    git clone https://github.com/Eric-Terminal/ETOS-LLM-Studio.git
    ```
2.  **環境要求**:
    *   Xcode 26.0+
    *   watchOS 26.0+ SDK
3.  **打開項目**:
    打開 `ETOS LLM Studio.xcworkspace`（注意是 **workspace** 不是 xcodeproj）。
    首次打開會自動解析並拉取 Swift Package 依賴。
4.  **運行**:
    選擇 `ETOS LLM Studio Watch App` 或 `ETOS LLM Studio iOS App` Target，連上設備（或模擬器），Command + R 即可。
5.  **配置**:
    啟動後，去設置裡添加你的 API Key。推薦使用「局域網調試」功能，直接把做好的 JSON 配置文件推送到 `Documents/Providers/` 目錄下 (真的有人會想在 Apple Watch 上面戳 API key 進去嗎)。

---

## 📬 聯繫方式

*   **開發者**: Eric Terminal
*   **Email**: ericterminal@gmail.com
*   **GitHub**: [Eric-Terminal](https://github.com/Eric-Terminal)

---

本次 README 修訂於 2026 年 3 月 7 日（7907e83 之後），軟件更新可能很勤快，README 可能更新不及時
