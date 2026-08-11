# ETOS LLM Studio

![Swift](https://img.shields.io/badge/Swift-FA7343?style=flat-square&logo=swift&logoColor=white)
![Platform](https://img.shields.io/badge/Platform-iOS%20%7C%20watchOS-blue?style=flat-square&logo=apple&logoColor=white)
![License](https://img.shields.io/badge/License-GPLv3-0052CC?style=flat-square)
![Build](https://img.shields.io/badge/Build-Passing-44CC11?style=flat-square)

**一個運行於 iOS 和 Apple Watch 的原生 AI / Agent 客戶端。支援 OpenAI、Anthropic Claude、Google Gemini 與本機 GGUF / llama.cpp 模型，並提供會話層級 Chat / Agent 模式、本地 Linux、Browser Agent、64 個 Apple 原生能力工具、MCP、可執行 Agent Skills、跨會話協作、本地 RAG 記憶、即時動態與雙端同步。**

[簡體中文](../../README.md) | [English](README_EN.md) | [Japanese](README_JA.md) | [Русский](README_RU.md)

---

## 📸 截圖

| | |
|:---:|:---:|
| <img src="../../assets/screenshots/screenshot-01.png" width="300"> | <img src="../../assets/screenshots/screenshot-02.png" width="300"> |

---

## 👋 寫在前面

在學校的日子其實挺無聊的，平時又總有很多問題想問 AI。當時我覺得 App Store 上的 AI 應用不是貴得離譜，就是功能殘缺到不太想用，尤其是手錶端，所以乾脆自己動手做了一個。

從最初那個只有 1,800 行程式碼、API Key 還要硬編碼的粗糙版本，到現在擁有 **971 個 Swift 原始碼檔案、362,394 行 Swift 程式碼**（僅計算專案內 Swift，不含 llama.cpp、iSH 子模組與 VitePress 文件站依賴）的工程，它確實已經長大了不少。雖然「ETOS LLM Studio」這個名字聽起來有點唬人，但本質上它還是我拿來探索大模型應用邊界的試驗場。

現在它也早就不只是手錶 App 了：iOS 與 watchOS 都能管理雲端模型、本機 GGUF 權重、工具、記憶、世界書與每日脈衝；Agent 還可以操作受控瀏覽器、調用 Apple 原生能力，或在 App 內建的本地 Linux 中執行指令與 Skill 腳本。兩端資料透過內建同步引擎互通。

因為我平常主要還是用 Mac 和 Watch，所以 iPhone 端偶爾還會有一些我想繼續打磨的細節，但我會慢慢補齊。

### 主要功能

#### 聊天與模型

*   **雙平台原生體驗**：原生適配 iOS 和 Apple Watch，整體風格一致，但會依不同螢幕尺寸分別優化操作體驗；iOS 會話列表採用卡片樣式，資料夾與會話分組清楚，橫向模式會自動切換成固定雙欄側邊欄佈局。
*   **會話管理增強**：支援會話全文檢索、命中內容預覽、訊息序號定位、資料夾分類、Finder 式彩色標籤、快速篩選、巢狀移動、批次操作、全螢幕會話管理入口與單會話跨端發送，會話歷史改為無限滾動載入。
*   **多模型支援**：原生適配 OpenAI Chat、OpenAI Responses、Anthropic（Claude）、Google（Gemini）等 API 格式，支援在 App 內管理提供商與模型，長按拖曳調整提供商順序，並可依自訂並行數對提供商底下所有模型批次執行連通性測試。
*   **端側本地模型**：支援匯入 GGUF 權重並作為「本地模型」提供商使用，底層透過 llama.cpp C ABI 橋接執行；支援流式輸出、GGUF Jinja chat template、本地工具調用解析、思考內容解析、本地嵌入模型路由與背景 detached completion。
*   **本地模型進階調參**：每個 GGUF 權重可按需覆寫上下文長度、輸出上限、GPU 層數、batch / ubatch、KV offload、flash attention、seed、採樣鏈、grammar、重複懲罰與對話範本透傳等參數，也支援常用 llama.cpp-style CLI 參數匯入、模型快取開關與 iOS 高記憶體限制。
*   **進階請求配置**：支援自訂請求頭、參數表達式、結構化請求控制、Key/Value Payload 編輯、原始 JSON 請求體與請求預覽，方便折騰相容 API 或特殊模型。
*   **訊息正規表示式規則**：支援以規則批次改寫送出與接收的訊息，可在偏好設定中管理多條規則，並可從提供商頁快速進入。
*   **單條 AI 回覆重寫**：可以對歷史中某條 AI 回覆單獨重寫，重寫時可引用同一訊息的其他版本，避免為了局部調整重跑整段會話。
*   **模型計費與費用估算**：支援為模型設定本地價格（含階梯式價格區間），自動依 Token 用量估算每則訊息的成本。
*   **多模態與圖像生成**：支援語音、圖片與檔案附件輸入；圖片可走獨立的 OCR 通道，檔案附件會在送出前文字化，圖像生成入口已收斂為助手圖片相簿。
*   **會話匯入匯出**：支援匯入 ETOS / `.elsbackup`、Cherry Studio、RikkaHub、Kelivo、ChatBox、ChatGPT conversations 等第三方會話，並可匯出 PDF / Markdown / TXT。
*   **語音輸入（STT）**：接入系統 `SFSpeechRecognizer` 流式辨識，iOS / watchOS 錄音流程已內嵌到聊天輸入列，支援即時轉寫、音訊直送與辨識結果回填輸入框。
*   **語音朗讀（TTS）**：支援系統 TTS、雲端 TTS 與自動回退，可獨立選擇 TTS 模型與朗讀參數。
*   **並行會話請求**：不同會話可保持獨立的請求狀態，支援會話層級取消、背景完成通知，以及由通知跳回對應聊天。

#### 顯示與閱讀體驗

*   **顯示系統可自訂**：支援自訂字體（含 WOFF / WOFF2）、字級比例、字體樣式槽位優先級、氣泡/文字顏色配置、聊天配色 Profile、依時間自動切換配色與關閉助手氣泡。
*   **本地性能監視面板**：iOS 使用本地模型聊天時可在輸入列上方顯示 CPU、Metal 與記憶體佔用，面板支援收合、拖曳、觸控透傳與位置記憶。
*   **氣泡功能列**：聊天氣泡下方可掛載自訂功能列，支援單行橫向滑動、關閉外圍邊框、iOS 與 watchOS 分別設定預設項目並隨使用者/助手身份切換，watchOS 可拖曳調整順序。
*   **字體回退策略**：支援整段/單字粒度的字體回退範圍設定，提升中英混排與符號場景的穩定性。
*   **思考與工具時間軸**：支援滾動思考預覽、自訂/響應式預覽高度、流式階段隱藏完整思考正文、思考耗時、非同步思考摘要、工具調用連線時間軸、錯誤重試續跑與多版本回覆切換；工具審批改造為列表式選項的原生問答 Sheet。
*   **Markdown 與程式碼區塊增強**：支援語法高亮、複製回饋、折疊切換、iOS 程式碼預覽、Mermaid 渲染、SwiftMath 數學公式、引用區塊左側豎線樣式、流式尾字淡入與掃光動效。
*   **watchOS 圖片閱讀**：Markdown 圖片與生成圖片預覽支援數位錶冠縮放與拖曳檢視，小螢幕也能認真看圖。

#### 工具與自動化

*   **工具中心 + 擴展工具**：統一管理 MCP / Shortcuts / 內建本地工具 / 自訂 JavaScript 工具 / Agent Skills 與內建 `getSystemTime` 等能力，支援依來源與用途分組、聊天工具開關、審批策略、會話層級啟用、分類收納與工具詳情頁。
*   **Agent Skills 技能包**：支援從本地資料夾、GitHub 倉庫連結、GitHub raw / 巢狀資料夾、預設分支與隱藏資料夾匯入技能包；技能資源支援多文字編碼讀取、大型文字分塊、文件抽取與圖片 OCR。啟用 Agent 模式與本地 Linux 後，Skill 可在逐次授權下執行 `scripts/` 中的腳本；Skill 目錄唯讀掛載，腳本版本與雜湊會隨 Run 凍結。
*   **結構化問答工具（ask_user_input）**：支援單題逐步作答、單選/多選互斥規則、自訂輸入與返回上一題。
*   **自訂 JavaScript 工具**：支援分離式 JS 執行與 AI 生成腳本工具，腳本保存在 `CustomJSTools` 獨立目錄，建立前會執行腳本驗證，可像普通工具一樣啟用、停用與配置審批策略。
*   **擴展工具能力補齊**：內建系統時間、SQLite 資料庫增刪改查、網頁卡片顯示、輸入框填入、沙盒檔案操作與反饋工單自動提交工具。
*   **沙盒檔案系統工具**：支援搜尋、分塊讀取、差異檢視、局部編輯、移動 / 複製 / 刪除等檔案操作。
*   **MCP 工具調用**：基於官方 Swift [Model Context Protocol](https://modelcontextprotocol.io) SDK，支援遠端調用、Streamable HTTP / SSE 傳輸、重新連線、逾時、握手治理、中繼資料刷新、資源/範本/提示詞讀取與能力協商；支援伺服器拖曳排序、工具層級啟用/審批策略、內建伺服器刪除與恢復，可依聊天暴露開關延遲自動連線。
*   **內建 MCP 伺服器**：內建搜尋、本地工具與個人資料 MCP 伺服器；個人資料伺服器會在工具真正調用時才按需申請 HealthKit、日曆與提醒事項權限。
*   **Siri 捷徑**：整合 Shortcuts 框架，可透過捷徑呼叫 AI，也支援自訂工具與 URL Scheme 路由。
*   **App 內檔案管理**：內建可瀏覽目錄的檔案管理器，可直接在 App 內檢視與管理沙盒檔案，純文字檔案可直接預覽。

#### Agent、原生能力與本地 Linux

*   **會話層級 Chat / Agent 模式**：模式隨會話保存。Chat 不向模型暴露 Agent 工具；Agent 未啟用 Linux 時仍可使用 Browser Agent、原生能力與會話協作，啟用本地 Linux 後才增加指令、Linux 檔案與本地 stdio MCP。使用者終端在兩種模式下都可獨立使用。
*   **App 內建本地 Linux**：以 `ish-multiarch` 嵌入最小 Alpine AArch64 RootFS，覆蓋 iOS 與 watchOS。系統按實際操作延遲安裝，打開開關不會立即啟動，也不會靜默安裝 Python、Node.js 或編譯工具；常用環境 recipe 會先展示確切指令、軟體來源與儲存影響。
*   **指令、PTY 與任務治理**：提供 `linux_run`、`linux_shell`、`linux_process`、互動式 PTY 終端、任務頁、輸出分頁、取消與診斷。使用者終端、Agent 指令與 Agent PTY 相互隔離，但共享已授權的 RootFS 與工作區；標準輸出會持續在背景收集。
*   **工作區、掛載與環境變數**：每個會話有獨立工作區，可將 App、iCloud Drive 或使用者明確授權的外部資料夾以唯讀或讀寫方式掛載至 Linux。環境變數儲存在 GRDB 並於程序啟動時注入，提供給模型、日誌與診斷的副本可遮蔽敏感值。
*   **統一檔案工具與本地 MCP**：現有檔案工具同時理解 `app://`、`linux://` 與 `mount://`。本地 stdio MCP 與 HTTP / SSE 伺服器共用管理頁、排序、工具開關與審批規則，並支援常見 `mcpServers` JSON 匯入匯出。
*   **Browser Agent**：iOS 受控 WKWebView 支援會話隔離分頁、DOM / 輔助使用快照、點擊、輸入、捲動、JavaScript、截圖、下載與使用者接管；watchOS 會探測本機真實能力，並可在使用者開啟後將缺失操作委託給配對 iPhone。
*   **64 個 Apple 原生工具**：依裝置、媒體與環境、個人資料、視覺與語言分為四組，涵蓋剪貼簿、通知、AlarmKit、地圖、裝置狀態、語音、媒體、WeatherKit、HomeKit、Bluetooth、NFC、聯絡人、照片、定位、Vision 與 NaturalLanguage。工具會回報真實平台可用性，寫入與外部副作用仍需逐次審批。
*   **持久會話協作**：Agent 可建立隱藏子代理或可見協作會話，選擇等待結果、背景交付或完成後續寫目前會話。結果依 session / run / tool 歸屬，避免多會話並行時互相串線。
*   **即時動態與背景完成通知**：iOS 會在鎖定畫面與動態島顯示 Chat / Agent 的執行、等待、完成或失敗狀態。App 進入背景後會使用 iOS 授予的有限執行時間繼續回覆或 Linux 任務；只有回覆確實在背景完成時才發送本地通知，系統掛起則會準確記錄為中斷。

#### 記憶與知識整理

*   **本地 RAG 記憶**：Embedding 可調用雲端 API，也可走已登記的本地嵌入模型，但**向量資料庫本身完全在本地 SQLite 上運行**；同時支援文字分塊、嵌入進度視覺化、記憶編輯、單條記憶重新嵌入、檢索時間戳發送控制與主動檢索工具。
*   **GRDB 關聯式持久化**：核心資料持久化從 JSON 遷移到 GRDB + SQLite，涵蓋會話、設定、MCP、世界書、記憶、反饋、捷徑、用量統計與全域提示詞等模組；底層可選開啟 SQLCipher 全盤實體加密。
*   **世界書（Worldbook）**：類似 SillyTavern 的 Lorebook 機制，支援背景設定管理、條件觸發、會話綁定隔離發送、system 注入與 URL 匯入；並進一步完善了 SillyTavern 多本同時注入、注入預算控制與欄位隔離的相容性。
*   **廣泛格式相容**：相容 PNG naidata、JSON 頂層陣列與 `character_book` 世界書格式。
*   **請求日誌與測速分析**：內建獨立請求日誌、Payload 詳情頁展開、可選的明文訊息記錄開關、細分 Token 匯總，並提供流式回應速度統計與詳情圖表。
*   **用量統計**：記錄文字請求、模型排行、Token 與快取 Token，提供 iOS / watchOS 雙端統計頁、綠色熱力圖、快取命中率與跨端同步；今日趨勢按小時切分，並提供按模型的 Token 趨勢圖、占比分析與全部歷史範圍。
*   **進階渲染**：內建 Markdown 渲染器，支援程式碼高亮、表格與 LaTeX 數學公式。

#### Daily Pulse 主動情報

*   **每日脈衝（Daily Pulse）**：每天先幫你整理一組主動情報卡片，把「今天可能值得看什麼」提前浮出來。
*   **Pulse 任務機制**：卡片可以直接轉成待跟進任務，未完成項目會跨天保留，並參與下一次 Pulse 生成。
*   **反饋歷史學習**：點讚、降權、隱藏、保存等操作會沉澱成長期偏好訊號，持續影響後續結果。
*   **晨間提醒與繼續聊**：支援定時提醒、通知快捷操作、儲存為會話與繼續聊天，iOS 與 watchOS 兩端都能接上這條流程。

#### 安全、同步與運維

*   **應用鎖**：基於 Keychain 持久化的 PBKDF2 主密碼搭配生物辨識（Face ID / Touch ID）雙重保護，支援修改密碼時驗證舊密碼、鎖屏自動喚起驗證，iOS 與 watchOS 均已接入。
*   **資料庫全盤加密**：透過 SQLCipher 對核心 SQLite 資料庫做實體層加密，支援加密遷移、新密碼校驗與從加密分庫讀取，App 內檔案瀏覽與除錯工具均相容。
*   **快照備份與加密**：基於 SQLite Online Backup API 構建脫機資料庫快照（含 FTS 剝離），支援完整快照模式、簡單密碼與 PBKDF2 雙模式 AES-256-GCM 加密，並提供二進位 `.elsbackup` 上傳與安全還原流程。
*   **跨端同步**：內建 iOS ↔ watchOS 同步引擎，可自動同步提供商配置、會話、會話標籤、世界書、工具設定、每日脈衝、用量統計、使用者畫像、全域提示詞等資料，並支援 Manifest/Delta 差異同步、WatchConnectivity 快速通道、iCloud 漫遊同步、會話分叉離線隔離與同訊息重試版本合併。
*   **多通道雲端備份**：支援 ETOS 數據包匯出/匯入、`.elsbackup` 快照匯入、手錶端全量匯入、CloudKit 傳輸（含 APNs 靜默推播觸發背景同步）、iCloud Drive 備份匯出/匯入、啟動備份與損壞自癒，以及透過 S3 相容物件儲存（AWS S3 / Cloudflare R2）簽名上傳快照、瀏覽遠端快照並自雲端下載還原。
*   **AppConfigStore 設定中心**：完全取代 `@AppStorage`，所有執行時設定走 GRDB 持久化、執行時快取讀取並以背景非同步寫入派發回主執行緒，避免主執行緒 I/O 與多裝置設定漂移；亦支援舊版 UserDefaults 設定的一次性遷移。
*   **更新時間軸**：無後端的版本追蹤系統，本地從 Build 資訊與快取重建發佈時間軸，AI 摘要以 Markdown 渲染，iOS 分批呈現、watchOS 拆分為二級頁瀏覽。
*   **App 內反饋助手**：支援反饋分類、環境資訊收集、Git 提交雜湊、PoW 提交流程、工單內評論對話、引用提交跳轉至更新時間軸、上傳分發通道資訊以及雙端同步。
*   **網路代理能力**：支援全域/提供商級 HTTP(S)/SOCKS 代理（含鑑權）。
*   **通知與反饋中心增強**：支援工單內評論對話、開發者標記展示、狀態自動刷新與高優先級本地通知跳轉。
*   **局域網除錯**：內建局域網除錯客戶端，並提供 Go 版 TUI 除錯工具與內建 Web 主控台；支援 Bonjour 自動發現、檔案/SQLite/Provider/模型進階配置/MCP 管理、App 設定編輯與 OpenAI 請求擷取。
*   **文件站**：新增 VitePress 文件站，涵蓋安裝、首聊、提供商設定、介面導覽、模組說明、設計文件與使用建議。
*   **本地化**：支援英文、簡體中文、繁體中文（香港）、日文、俄文、法文、西班牙文、阿拉伯文共 8 種語言，並可在 App 內切換語言。

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

*   **語言**: Swift 6, C / C++（llama.cpp 與 iSH 公共橋接層）
*   **UI**: SwiftUI
*   **架構**: MVVM + Protocol Oriented Programming
*   **資料**: GRDB + SQLite + SQLCipher（核心持久化、本地向量資料庫與可選的全盤實體加密）, JSON（匯入匯出與相容格式）
*   **設定**: AppConfigStore（取代 `@AppStorage`，GRDB 持久化 + 執行時快取 + 背景非同步寫入）
*   **安全**: SQLCipher 全盤加密、Keychain PBKDF2 主密碼、LocalAuthentication 生物辨識、AES-256-GCM 快照加密
*   **網路與傳輸**: URLSession（API 請求）, Streamable HTTP / SSE（MCP 傳輸）, WatchConnectivity / CloudKit / APNs 靜默推播（跨端與雲端傳輸）, WebSocket / HTTP Polling（局域網除錯）
*   **AI 協議**: Model Context Protocol（基於官方 [swift-sdk](https://github.com/modelcontextprotocol/swift-sdk)）, OpenAI Chat / Responses, Anthropic Messages, Gemini API, 本地 `local-llama-cpp` 提供商
*   **本地推理**: llama.cpp / GGUF, Swift ↔ C ABI ↔ C++ 橋接, CMake + Ninja 預編譯 `libetos-llama.a`, Accelerate / Metal（watchOS 執行期固定 CPU 路徑）
*   **本地 Agent Runtime**: `ish-multiarch`、內建 Alpine AArch64 RootFS、Meson + Ninja 預編譯 `libiSHApple.a`、PTY、動態掛載、guest 檔案 API 與本地 stdio MCP
*   **Agent 能力**: 64 個 Apple 原生 MCP 工具、WKWebView Browser Agent、可執行 Agent Skills、持久會話協作與按 Run 凍結的權限上下文
*   **系統能力**: Siri Shortcuts, WatchConnectivity, CloudKit, UserNotifications, ActivityKit / WidgetKit, iOS 有限背景任務, LocalAuthentication, Speech / AVFoundation
*   **文件站**: VitePress / Teek（僅文件站使用；README 中的程式碼規模不統計其依賴）
*   **依賴管理**: Swift Package Manager（當前顯式依賴 `GRDB.swift`（Eric-Terminal fork）、`SQLCipher.swift`、`swift-sdk`（MCP）、`swift-markdown-ui`、`SwiftMath`、`ZIPFoundation`、`Cepheus`（watchOS 第三方鍵盤），並包含其傳遞依賴 `networkimage`、`swift-cmark`、`eventsource`、`swift-nio` 等）+ llama.cpp / ish-multiarch Git 子模組 + 獨立靜態庫構建腳本

---

## 🏗️ 專案架構

專案採用雙層結構：平台無關的 ETOSCore 框架 + 各平台獨立的視圖層。Chat、Agent 編排、原生工具、Browser Agent、本地 Linux、MCP 與 Skills 都先進入 ETOSCore 的統一執行上下文、審批、審計與持久化邊界，再由 iOS / watchOS 提供平台介面與系統能力實作。

```
ETOSCore/ETOSCore/                         ← 平台無關業務邏輯（481 個 Swift 原始碼檔案）
├── AppTool/                            ← 本地工具、自訂 JS 工具、ask_user_input、SQLite 與沙盒檔案工具
├── Attachments/                        ← 檔案附件文字抽取
├── BrowserAgent/                       ← 受控瀏覽器會話、DOM 自動化、截圖、下載、Cookie 與 iPhone 委託
├── Chat/                               ← 聊天模型、訊息版本、匯出、渲染狀態
│   ├── ConversationRuntime/            ← 持久協作會話、子代理、等待圖、預算與續寫
│   └── Service/                        ← ChatService 請求編排、回應解析、重試、工具、記憶與世界書注入
├── Config/                             ← AppConfigStore 設定中心、鍵定義與舊版 UserDefaults 遷移
├── ConfigLoader/                       ← Provider 設定、SQLite 儲存、背景與一次性下載狀態
├── Core/                               ← 核心模型、JSONValue、請求體控制與共用基礎設施
├── DailyPulse/                         ← 每日脈衝生成、篩選、投遞、反饋與任務資料
├── Feedback/                           ← App 內反饋助手、環境採集、DTO 與本地儲存
├── Font/                               ← 自訂字體庫、字體路由與回退範圍
├── LocalDebugServer/                   ← 局域網除錯客戶端、Web 主控台、檔案 / SQLite / Provider 指令與請求擷取
├── LocalAgentRuntime/                  ← 本地 Linux、RootFS、PTY、工作區、掛載、任務、審批與 iSH C ABI
├── LocalLLM/                            ← 本地 GGUF 模型記錄、提供商橋接、參數映射與 Swift 推理入口
├── LocalLLMBridge/                      ← llama.cpp C ABI / C++ 橋接層與靜態庫連結邊界
├── Math/                               ← LaTeX/數學公式渲染引擎
├── MCP/                                ← MCP 客戶端、內建伺服器、伺服器儲存、Streamable HTTP / SSE 傳輸（基於官方 swift-sdk）
├── Memory/ + SimilaritySearch/         ← 本地 RAG、嵌入、分塊、SQLite 向量檢索
├── NativeCapabilities/                 ← 64 個 Apple 原生能力的定義、執行器、權限與雙端委託
├── Parsing/                            ← 請求頭與參數表達式解析
├── Persistence/                        ← GRDB 主庫/輔助庫、遷移、啟動備份、媒體與檔案儲存
├── Providers/                          ← Provider 模型、代理設定與 OpenAI / Anthropic / Gemini 適配器
├── Roleplay/                           ← 角色扮演人設、聊天提示詞範本與預設角色庫
├── Security/                           ← 應用鎖狀態機、PBKDF2 主密碼與資料庫加密管理
├── Shortcuts/                          ← Siri 捷徑、URL Router、匯入與執行中繼
├── Skills/                             ← Agent Skills 匯入、資源讀取、腳本快照、授權與本地 Linux 執行
├── Snapshot/                           ← 資料庫脫機快照構建、AES-256-GCM 加密與安全還原
├── Storage/                            ← 沙盒檔案瀏覽、儲存統計、快取清理
├── Sync/                               ← WatchConnectivity 快速通道 / CloudKit / iCloud 漫遊 / Manifest / Delta / iCloud Drive / S3 與第三方匯入
├── System/                             ← 全域提示詞、通知、公告、日誌、語音辨識、OCR、更新時間軸
├── TTS/                                ← 系統 / 雲端朗讀、佇列播放、設定與預設
├── UI/                                 ← 跨端 UI 元件（應用鎖介面、跑馬燈文字等）
├── UsageAnalytics/                     ← 用量事件、統計儀表板、按小時趨勢與模型 Token 占比
└── Worldbook/                          ← 世界書模型、匯入匯出、SQLite 儲存與觸發引擎

ETOS LLM Studio/ETOS LLM Studio iOS App/    ← iOS 視圖層（187 個 Swift 原始碼檔案）
ETOS LLM Studio/ETOS LLM Studio Watch App/  ← watchOS 視圖層（156 個 Swift 原始碼檔案）
ETOS LLM Studio/ETOS Agent Widgets/          ← iOS Widget 與即時動態
ETOS LLM Studio/ETOS Agent Watch Widgets/    ← watchOS Widget
ETOS LLM Studio/ETOS Workspace Provider/     ← Files / File Provider 系統入口
ETOS LLM Studio/ETOS Agent Share/            ← 分享擴充系統入口
ETOSCore/ETOSCoreTests/                       ← ETOSCore 層測試（147 個 Swift 原始碼檔案）
```

雲端模型資料流：`View → ChatViewModel → ChatService.shared → Provider Adapter → LLM API`。本地模型資料流：`View → ChatViewModel → ChatService.shared → LocalLLMEngine → LocalLLMBridge → libetos-llama.a / llama.cpp`。Agent 工具資料流：`ChatService → AgentRuntimeContext → 審批與審計 → BrowserAgent / NativeCapabilities / MCP / Skills / LocalAgentRuntime → libiSHApple.a`。會話、Run、工具、記憶、世界書、用量統計與同步資料皆由 ETOSCore 服務與 GRDB / SQLite 統一治理。

---

## 🚀 編譯指南

如果你想自己動手：

1.  **Clone 專案並拉取子模組**:
    ```bash
    git clone --recurse-submodules https://github.com/Eric-Terminal/ETOS-LLM-Studio.git
    cd ETOS-LLM-Studio
    ```
    如果已經 Clone 過但缺少 `Dependencies/llama.cpp` 或 `Dependencies/ish-multiarch`，執行：
    ```bash
    git submodule update --init --recursive
    ```
2.  **環境需求**:
    *   Xcode 26.0+
    *   watchOS 26.0+ SDK
    *   CMake + Ninja（構建 llama.cpp）
    *   Meson + Ninja（構建 iSHApple）
    *   建議直接執行 `brew install cmake ninja meson`
    *   （如果環境對不上，你可以自行調整相容性）
3.  **編譯前先生成原生靜態庫**:
    Xcode 不會在普通 Build Phase 中反覆編譯 llama.cpp 與 iSH。統一入口會分別調用兩套構建腳本，並將兩個獨立靜態庫放進同一 Xcode 搜尋目錄；它們不會被合併成一份 `.a`。

    真機 / Release：
    ```bash
    CONFIGURATION=Release SDK_NAME=iphoneos PLATFORM_NAME=iphoneos ARCHS=arm64 scripts/build-native-static-libraries.sh --parallel
    CONFIGURATION=Release SDK_NAME=watchos PLATFORM_NAME=watchos ARCHS="arm64 arm64_32" scripts/build-native-static-libraries.sh --parallel
    ```
    README 使用的 iOS + watchOS Debug 模擬器：
    ```bash
    CONFIGURATION=Debug SDK_NAME=iphonesimulator PLATFORM_NAME=iphonesimulator ARCHS=arm64 scripts/build-native-static-libraries.sh --parallel
    CONFIGURATION=Debug SDK_NAME=watchsimulator PLATFORM_NAME=watchsimulator ARCHS=arm64 scripts/build-native-static-libraries.sh --parallel
    ```
    首次執行會構建 iSHApple 的 iOS / watchOS 裝置與模擬器切片，以及目前命令要求的 llama.cpp 平台產物，因此會比快取構建慢很多。兩套依賴各自驗證快取，修改 iSH 不會重編 llama.cpp，反之亦然。`--parallel` 預設使用本機 CPU 數，也可用 `--parallel=8`、`--jobs 8` 或 `-j8` 指定任務數。

    | 產物 | 位置 | 用途 |
    | --- | --- | --- |
    | `iSHApple.xcframework` | `Dependencies/ish-build/iSHApple.xcframework` | iSH 公共多平台產物 |
    | `libiSHApple.a` | `Dependencies/ish-build/products/<platform>/` | 各平台原始 iSH 靜態庫 |
    | `libetos-llama.a` | `Dependencies/llama-build/products/<platform>-<configuration>/` | llama.cpp / ggml / mtmd |
    | 暫存的 `libiSHApple.a` | 與 `libetos-llama.a` 同目錄 | 供目前 Xcode SDK / Configuration 搜尋與連結 |

    ETOSCore 以 `-letos-llama` 連結 llama.cpp；iOS / watchOS 的 Linux 薄橋以物件連結選項額外連結 `-liSHApple`，所以 Xcode 會直接使用兩份靜態庫。生成目錄已被 Git 忽略，不應提交。
4.  **打開專案**:
    打開 `ETOS LLM Studio.xcworkspace`（注意是 **workspace**，不是 xcodeproj）。
    首次打開時，Xcode 會自動解析並拉取 Swift Package 依賴。
5.  **運行**:
    選擇 `ETOS LLM Studio App` Scheme 運行 iOS App；如果要單獨除錯 watchOS，再選擇 `ETOS LLM Studio Watch App` Scheme。連上裝置（或模擬器）後，按 Command + R 即可。
6.  **設定**:
    啟動後，請先在設定中加入你的 API Key。我很建議直接使用「局域網除錯」功能，把準備好的 JSON 配置檔直接推到 `Documents/Providers/` 目錄（畢竟，真的沒什麼人會想在 Apple Watch 上慢慢敲 API Key）。

### 常見編譯問題

*   `ish-multiarch 子模組未初始化`：執行 `git submodule update --init --recursive`。
*   找不到 `meson`、`ninja` 或 `cmake`：執行 `brew install cmake ninja meson`，再重新執行原生靜態庫腳本。
*   `library 'etos-llama' not found` 或 `library 'iSHApple' not found`：確認腳本的 `SDK_NAME`、`PLATFORM_NAME` 與 `CONFIGURATION` 和 Xcode 目前目標一致。
*   watchOS 真機封存缺少架構：使用 `ARCHS="arm64 arm64_32"` 重新生成 `watchos` Release 產物。
*   本機環境變數造成 watchOS 連結異常：使用下一節的 `env -u ... xcodebuild` 標準命令。

---

## 🧪 自動化測試與構建

如需在命令列執行一鍵編譯或單元測試，請統一使用以下標準 `xcodebuild` 命令（已配置隔離環境變數，避免本機環境污染導致的 watchOS 連結失敗）：

* **構建 iOS App（自動包含 watch App）**：
  ```bash
  env -u SDKROOT -u LIBRARY_PATH -u CPATH -u C_INCLUDE_PATH -u CPLUS_INCLUDE_PATH -u OBJC_INCLUDE_PATH xcodebuild -workspace 'ETOS LLM Studio.xcworkspace' -scheme 'ETOS LLM Studio App' -destination 'platform=iOS Simulator,name=iPhone 17 Pro,OS=26.5' build
  ```
* **單獨驗證 watchOS App 構建**：
  ```bash
  env -u SDKROOT -u LIBRARY_PATH -u CPATH -u C_INCLUDE_PATH -u CPLUS_INCLUDE_PATH -u OBJC_INCLUDE_PATH xcodebuild -workspace 'ETOS LLM Studio.xcworkspace' -scheme 'ETOS LLM Studio Watch App' -destination 'generic/platform=watchOS Simulator' build
  ```
* **運行 ETOSCore 核心框架單元測試**（147 個測試原始碼檔案，50,853 行測試程式碼）：
  ```bash
  env -u SDKROOT -u LIBRARY_PATH -u CPATH -u C_INCLUDE_PATH -u CPLUS_INCLUDE_PATH -u OBJC_INCLUDE_PATH xcodebuild -workspace 'ETOS LLM Studio.xcworkspace' -scheme 'ETOSCore' -destination 'platform=iOS Simulator,name=iPhone 17 Pro,OS=26.5' -parallel-testing-enabled NO test
  ```
* **運行 iOS App 單元與 UI 測試**：
  ```bash
  env -u SDKROOT -u LIBRARY_PATH -u CPATH -u C_INCLUDE_PATH -u CPLUS_INCLUDE_PATH -u OBJC_INCLUDE_PATH xcodebuild -workspace 'ETOS LLM Studio.xcworkspace' -scheme 'ETOS LLM Studio App' -destination 'platform=iOS Simulator,name=iPhone 17 Pro,OS=26.5' -parallel-testing-enabled NO test
  ```
* **運行 watchOS App 單元與 UI 測試**：
  ```bash
  env -u SDKROOT -u LIBRARY_PATH -u CPATH -u C_INCLUDE_PATH -u CPLUS_INCLUDE_PATH -u OBJC_INCLUDE_PATH xcodebuild -workspace 'ETOS LLM Studio.xcworkspace' -scheme 'ETOS LLM Studio Watch App' -destination 'platform=watchOS Simulator,name=Apple Watch Series 11 (46mm),OS=26.5' -parallel-testing-enabled NO test
  ```

---

## 📬 聯絡方式

*   **開發者**: Eric Terminal
*   **Email**: ericterminal@ericterminal.com
*   **GitHub**: [Eric-Terminal](https://github.com/Eric-Terminal)

---

本次 README 修訂於 2026 年 8 月 12 日。專案更新速度很快，如果 README 一時跟不上程式碼，最準的還是提交記錄。
