# ETOS LLM Studio

![Swift](https://img.shields.io/badge/Swift-FA7343?style=flat-square&logo=swift&logoColor=white)
![Platform](https://img.shields.io/badge/Platform-iOS%20%7C%20watchOS-blue?style=flat-square&logo=apple&logoColor=white)
![License](https://img.shields.io/badge/License-GPLv3-0052CC?style=flat-square)
![Build](https://img.shields.io/badge/Build-Passing-44CC11?style=flat-square)

**一個運行於 iOS 和 Apple Watch 的原生 AI 客戶端。支援 OpenAI、Anthropic Claude、Google Gemini 等多個模型提供商，內建 MCP 工具調用、本地 RAG 記憶、世界書、每日脈衝、Siri 捷徑與雙端同步。**

[簡體中文](../../README.md) | [English](README_EN.md) | [Japanese](README_JA.md) | [Русский](README_RU.md)

---

## ✨ 最近新增亮點

*   **會話管理升級（3.27 ~ 4.06）**：支援 iOS / watchOS 會話全文檢索、訊息序號定位、資料夾分類、批次移動，以及單會話跨端發送。
*   **匯入匯出能力補齊**：新增第三方匯入（Cherry Studio、RikkaHub、Kelivo、ChatGPT conversations），並支援會話匯出 PDF / Markdown / TXT。
*   **同步與備份 2.0**：新增 ETOS 數據包匯入匯出、手錶端全量匯入，以及「輸入地址後直接 POST 上傳導出包」能力。
*   **顯示系統大改版**：支援自訂字體（含 WOFF / WOFF2）、字體樣式槽位優先級、氣泡/文字顏色配置、無氣泡 UI，且思考自動預覽預設開啟。
*   **Markdown 與程式碼區塊體驗增強**：新增語法高亮、複製回饋、折疊切換、iOS 程式碼預覽、Mermaid 圖表渲染與引用區塊左側豎線樣式。
*   **工具中心持續擴展**：新增 Agent Skills 全鏈路接入與匯入能力、ask_user_input 結構化問答工具、網頁卡片顯示工具與反饋工單自動提交工具。
*   **網路與語音能力加強**：支援全域/提供商級 HTTP(S)/SOCKS 代理（含鑑權），並接入系統流式 STT 語音輸入（iOS + watchOS）。
*   **反饋與通知體驗升級**：反饋中心支援工單內評論對話、開發者標記展示、狀態自動刷新，以及對應的高優先級本地通知跳轉。

---

## 📸 截圖

| | |
|:---:|:---:|
| <img src="../../assets/screenshots/screenshot-01.png" width="300"> | <img src="../../assets/screenshots/screenshot-02.png" width="300"> |

---

## 👋 寫在前面

在學校的日子其實挺無聊的，平時又總有很多問題想問 AI。當時我覺得 App Store 上的 AI 應用不是貴得離譜，就是功能殘缺到不太想用，尤其是手錶端，所以乾脆自己動手做了一個。

從最初那個只有 1,800 行程式碼、API Key 還要硬編碼的粗糙版本，到現在擁有 **223 個 Swift 原始碼檔案、119,112 行程式碼**（含 Shared / iOS / watchOS / 測試）的工程，它確實已經長大了不少。雖然「ETOS LLM Studio」這個名字聽起來有點唬人，但本質上它還是我拿來探索大模型應用邊界的試驗場。

現在它也早就不只是手錶 App 了：我把 iOS 端慢慢補成了更完整的版本，方便在手機上管理模型、工具、記憶、世界書與每日脈衝；兩端資料還能透過內建同步引擎自動互通。

因為我平常主要還是用 Mac 和 Watch，所以 iPhone 端偶爾還會有一些我想繼續打磨的細節，但我會慢慢補齊。

### 主要功能

#### 聊天與模型

*   **雙平台原生體驗**：原生適配 iOS 和 Apple Watch，整體風格一致，但會依照不同螢幕尺寸調整操作體驗。
*   **多模型支援**：原生適配 OpenAI、Anthropic（Claude）、Google（Gemini）等 API 格式，支援在 App 內管理提供商與模型。
*   **進階請求配置**：支援自訂請求頭、參數表達式、原始 JSON 請求體，方便折騰相容 API 或特殊模型。
*   **多模態與圖像生成**：支援語音輸入、圖片輸入，以及 AI 圖像生成。
*   **語音輸入（STT）**：接入系統 `SFSpeechRecognizer` 流式辨識，錄音面板可即時轉寫並一鍵回填輸入框。
*   **語音朗讀（TTS）**：支援系統 TTS、雲端 TTS 與自動回退，可獨立選擇 TTS 模型與朗讀參數。

#### 工具與自動化

*   **工具中心 + 擴展工具**：統一管理 MCP、Shortcuts、本地工具三類能力，支援工具開關、審批策略與會話級啟用。
*   **Agent Skills**：支援技能全鏈路接入、工具中心統一開關管理，並可在 iOS 從本地檔案匯入、在 watchOS 透過 URL 下載匯入。
*   **結構化問答工具（ask_user_input）**：支援單題逐步作答、單選/多選互斥規則、自訂輸入與返回上一題。
*   **沙盒檔案系統工具**：支援搜尋、分塊讀取、差異查看、局部編輯、移動 / 複製 / 刪除等檔案操作。
*   **MCP 工具調用**：支援遠端 [Model Context Protocol](https://modelcontextprotocol.io)，包含完整 MCP 客戶端、Streamable HTTP/SSE 傳輸、重連、超時、握手治理與能力協商。
*   **Siri 捷徑**：整合 Shortcuts 框架，可透過捷徑呼叫 AI，也支援自訂工具與 URL Scheme 路由。
*   **App 內檔案管理**：內建檔案管理器，可直接在 App 內瀏覽與管理沙盒檔案。

#### 記憶與知識整理

*   **本地 RAG 記憶**：Embedding 可調用雲端 API，但**向量資料庫本身完全在本地 SQLite 上運行**；同時支援文本分塊、嵌入進度視覺化、記憶編輯與主動檢索工具。
*   **世界書（Worldbook）**：類似 SillyTavern 的 Lorebook 機制，支援背景設定管理、條件觸發、會話綁定隔離發送、system 注入與 URL 匯入。
*   **廣泛格式相容**：相容 PNG naidata、JSON 頂層陣列與 `character_book` 世界書格式。
*   **請求日誌與測速分析**：內建獨立請求日誌、細分 Token 匯總，並提供流式回應速度統計與圖表。
*   **高級渲染**：內建 Markdown 渲染器，支援程式碼高亮、表格與 LaTeX 數學公式。

#### Daily Pulse 主動情報

*   **每日脈衝（Daily Pulse）**：每天先幫你整理一組主動情報卡片，把「今天可能值得看什麼」提前浮出來。
*   **Pulse 任務機制**：卡片可以直接轉成待跟進任務，未完成項目會跨天保留，並參與下一次 Pulse 生成。
*   **反饋歷史學習**：點讚、降權、隱藏、保存等操作會沉澱成長期偏好訊號，持續影響後續結果。
*   **晨間提醒與繼續聊**：支援定時提醒、通知快捷操作、保存為會話與繼續聊天，iOS 與 watchOS 兩端都能接上這條流程。

#### 同步、調試與運維

*   **跨端同步**：內建 iOS ↔ watchOS 同步引擎，可自動同步提供商配置、會話、世界書、工具設定、每日脈衝資料等內容。
*   **同步與備份**：支援 ETOS 數據包導出/匯入、手錶端全量匯入，以及透過自訂地址直接上傳導出包。
*   **App 內反饋助手**：支援反饋分類、環境資訊收集、PoW 提交流程與雙端同步。
*   **局域網調試**：內建局域網調試客戶端，並提供 Go 版調試服務與內建 Web 控制台，可在瀏覽器管理 App 內檔案與會話資料。
*   **本地化**：支援英文、簡體中文、繁體中文（香港）、日文、俄文、法文、西班牙文、阿拉伯文共 8 種語言。

---

## 💸 關於收費與開源

說實話，我最開始是想把它做成免費軟體的。
但 Apple Developer Program 每年 99 美元的費用，對一個學生來說確實不算輕鬆。

後來有位投資人幫我先墊了這筆錢，條件是我要透過軟體收入慢慢還回去（而且還要分成）。所以 App Store 版本象徵性地收了一點費用。你可以把它理解成一種幫我續命開發、同時順便買到「不用每七天重簽一次」便利性的方式。

**但開源依然是我的底線。**

所以規則很簡單：
1.  **想省事 / 想支持我**：App Store 見，謝謝你的「可樂錢」。
2.  **想自己折騰 / 想免費用**：程式碼就在這裡，採用 GPLv3。如果你有 Mac 和 Xcode，**完全可以自己編譯安裝，而且功能沒有任何差異**。
3.  **想先體驗最新版本**：可以加入 TestFlight 👉 [https://testflight.apple.com/join/d4PgF4CK](https://testflight.apple.com/join/d4PgF4CK)

技術應該被共享。我不希望只是因為一點點價格門檻，就把同樣對程式碼有興趣的人擋在外面。

---

## 🛠️ 技術棧

*   **語言**: Swift 6
*   **UI**: SwiftUI
*   **架構**: MVVM + Protocol Oriented Programming
*   **資料**: SQLite（本地向量庫）, JSON（配置與資料持久化）
*   **網路與傳輸**: URLSession（API 請求）, Streamable HTTP / SSE（MCP 傳輸）, WebSocket / HTTP Polling（局域網調試）
*   **AI 協議**: Model Context Protocol (MCP)
*   **系統能力**: Siri Shortcuts, WatchConnectivity, UserNotifications, BackgroundTasks（iOS）
*   **依賴管理**: Swift Package Manager（當前顯式依賴 `swift-markdown-ui`，並包含其傳遞依賴 `networkimage` 與 `swift-cmark`）

---

## 🏗️ 專案架構

專案採用雙層結構：平台無關的 Shared 框架 + 各平台獨立的視圖層。

```
Shared/Shared/                  ← 平台無關的業務邏輯（83 個 Swift 原始碼檔案）
├── ChatService.swift            ← 管理會話、訊息、模型選擇與請求編排的核心單例
├── APIAdapter.swift             ← OpenAI / Anthropic / Gemini 等 API 適配層
├── Models.swift                 ← 核心資料模型
├── Persistence.swift            ← 配置與資料持久化
├── DailyPulse.swift             ← 每日脈衝引擎、卡片、反饋與任務資料
├── DailyPulseDeliveryCoordinator.swift ← 晨間提醒、投遞狀態與準備窗口協調
├── Memory/                      ← 記憶子系統（分塊、嵌入、存儲）
├── SimilaritySearch/            ← 本地向量資料庫（SQLite）
├── MCP/                         ← Model Context Protocol 客戶端與傳輸層
├── Feedback/                    ← App 內反饋助手（收集、簽名、存儲、上傳）
├── Worldbook/                   ← 世界書引擎、匯入與匯出
├── Sync/                        ← iOS ↔ watchOS 同步引擎
├── TTS/                         ← 語音朗讀播放、設定與預設
├── Shortcuts/                   ← Siri 捷徑與 URL 路由整合
├── AppToolManager.swift         ← 本地工具與工具目錄治理
├── StorageBrowserSupport.swift  ← 檔案瀏覽與管理能力支援
└── LocalDebugServer.swift       ← 局域網調試客戶端

ETOS LLM Studio/ETOS LLM Studio iOS App/    ← iOS 視圖層（44 個 Swift 原始碼檔案）
ETOS LLM Studio/ETOS LLM Studio Watch App/  ← watchOS 視圖層（47 個 Swift 原始碼檔案）
Shared/SharedTests/                         ← Shared 層測試（49 個 Swift 原始碼檔案）
```

資料流為 `View → ChatViewModel → ChatService.shared → APIAdapter → LLM API`，並透過 Combine Subjects 驅動 UI 更新。

---

## 🚀 編譯指南

如果你想自己動手：

1.  **Clone 專案**:
    ```bash
    git clone https://github.com/Eric-Terminal/ETOS-LLM-Studio.git
    ```
2.  **環境需求**:
    *   Xcode 26.0+
    *   watchOS 26.0+ SDK
    *   （如果環境對不上，你可以自行調整相容性）
3.  **打開專案**:
    打開 `ETOS LLM Studio.xcworkspace`（注意是 **workspace**，不是 xcodeproj）。
    首次打開時，Xcode 會自動解析並拉取 Swift Package 依賴。
4.  **運行**:
    選擇 `ETOS LLM Studio Watch App` 或 `ETOS LLM Studio iOS App` Target，連上裝置（或模擬器），然後按 Command + R。
5.  **配置**:
    啟動後，請先在設定中加入你的 API Key。我很建議直接使用「局域網調試」功能，把準備好的 JSON 配置檔直接推到 `Documents/Providers/` 目錄（畢竟，真的沒什麼人會想在 Apple Watch 上慢慢敲 API Key）。

---

## 📬 聯絡方式

*   **開發者**: Eric Terminal
*   **Email**: ericterminal@gmail.com
*   **GitHub**: [Eric-Terminal](https://github.com/Eric-Terminal)

---

本次 README 修訂於 2026 年 4 月 8 日（99b6f19 之後）。專案更新速度很快，如果 README 一時跟不上程式碼，最準的還是提交記錄。
