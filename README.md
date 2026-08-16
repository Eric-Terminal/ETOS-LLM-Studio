# ETOS LLM Studio

![Swift](https://img.shields.io/badge/Swift-FA7343?style=flat-square&logo=swift&logoColor=white)
![Platform](https://img.shields.io/badge/Platform-iOS%20%7C%20watchOS-blue?style=flat-square&logo=apple&logoColor=white)
![License](https://img.shields.io/badge/License-GPLv3-0052CC?style=flat-square)
![Build](https://img.shields.io/badge/Build-Passing-44CC11?style=flat-square)

**一个运行在 iOS 和 Apple Watch 上的原生 AI / Agent 客户端。支持 OpenAI、Anthropic Claude、Google Gemini 与本机 GGUF / llama.cpp 模型，并提供会话级 Chat / Agent 模式、本地 Linux、Browser Agent、64 个 Apple 原生能力工具、MCP、Agent Skills、跨会话协作、本地 RAG 记忆、实时活动与双端同步。**

[English](docs/readme/README_EN.md) | [繁體中文](docs/readme/README_ZH_HANT.md) | [日本語](docs/readme/README_JA.md) | [Русский](docs/readme/README_RU.md)

---

## 📸 截图

| | |
|:---:|:---:|
| <img src="assets/screenshots/screenshot-01.png" width="300"> | <img src="assets/screenshots/screenshot-02.png" width="300"> |

---

## 👋 写在前面

在学校的日子挺无聊的，平时又总会冒出很多想问 AI 的问题。当时我嫌 App Store 上的 AI 应用要么贵得离谱，要么功能太残废（尤其是手表端），索性就自己动手搓了一个。

从最初那个只有 1,800 行代码、API Key 还要硬编码的简陋版本，到现在 **971 个 Swift 源文件、362,394 行 Swift 代码**（仅计算项目内 Swift，不把 llama.cpp、iSH 子模块和 VitePress 文档站依赖算进来）的工程，它确实已经长大了不少。虽然名字叫 "ETOS LLM Studio" 听着有点唬人，但它本质上还是我拿来探索大模型应用边界的试验场。

现在它已经不只是一个手表端 App 了：iOS 和 watchOS 都能管理云端模型、本地 GGUF 权重、工具、记忆、世界书和每日脉冲；Agent 还可以操作受控浏览器、调用 Apple 原生能力，或在 App 内置的本地 Linux 中运行命令与 Skill 脚本。两端数据通过内置同步引擎互通。

因为我平时主要还是用 Mac 和 Watch，iPhone 端偶尔会有一些还在继续打磨的边角，不过我会继续慢慢补齐。

### 主要功能

#### 聊天与模型

*   **双端原生体验**：iOS 和 Apple Watch 原生适配，两端界面风格统一，但会针对不同屏幕尺寸分别优化交互；iOS 会话列表采用卡片样式，文件夹与会话分组分明，横屏自动切换为固定双栏侧栏布局。
*   **会话管理增强**：支持会话全文检索、命中上下文预览、消息序号定位、文件夹分类、Finder 式彩色标签、快捷筛选、嵌套移动、批量操作、全屏会话管理入口与单会话跨端发送，会话历史改为无限滚动加载。
*   **多模型支持**：原生适配 OpenAI Chat、OpenAI Responses、Anthropic（Claude）和 Google（Gemini）等接口格式，支持在 App 内动态管理提供商与模型，拉取模型列表，并可长按拖动调整提供商顺序。
*   **端侧本地模型**：支持导入 GGUF 权重并作为“本地模型”提供商使用，底层通过 llama.cpp C ABI 桥接执行；支持流式输出、GGUF Jinja chat template、本地工具调用解析、思考内容解析、本地嵌入模型路由与后台 detached completion。
*   **本地模型高级调参**：每个 GGUF 权重可挂载独立的 LoRA GGUF Adapter 并调节强度，也可按需覆盖上下文长度、输出上限、GPU 层数、batch / ubatch、KV offload、flash attention、seed、采样链、grammar、重复惩罚与对话模板透传等参数；同时支持常用 llama.cpp-style CLI 参数导入、模型缓存开关和 iOS 高内存限制。
*   **高级请求配置**：支持自定义请求头、参数表达式、结构化请求控制、键值对 Payload 编辑、原始 JSON 请求体与请求预览，方便折腾兼容接口和特殊模型。
*   **消息正则替换规则**：支持对发送与接收消息按规则批量改写，可在偏好设置中管理多条规则并随提供商页快速进入。
*   **单条 AI 回复重写**：可以对历史中某条 AI 回复单独重写，重写时可引用同一消息的其他版本，避免为了局部调整重跑整段会话。
*   **模型计费与费用估算**：支持为模型配置本地价格（含阶梯价格区间），自动按 Token 用量估算每条消息的成本。
*   **多模态与图像生成**：支持发送语音、图片与文件附件；图片可走独立 OCR 通道，文件附件会在发送前文本化，图像生成入口已收敛为助手图片相册。
*   **会话导入导出**：支持导入 ETOS / `.elsbackup`、Cherry Studio、RikkaHub、Kelivo、ChatBox、ChatGPT conversations 等第三方会话，并可导出 PDF / Markdown / TXT。
*   **语音输入（STT）**：接入系统 `SFSpeechRecognizer` 流式识别，iOS / watchOS 录音流程内嵌到聊天输入栏，支持实时转写、音频直发和识别结果回填输入框。
*   **语音朗读（TTS）**：支持系统 TTS、云端 TTS 与自动回退，可单独选择 TTS 模型和朗读参数。
*   **并发会话请求**：不同会话可以保持独立请求状态，支持会话级取消、后台完成通知与通知跳转回对应聊天。

#### 显示与阅读体验

*   **显示系统可定制**：支持自定义字体（含 WOFF / WOFF2）、字号比例、字体样式槽位优先级、气泡/文字颜色配置、聊天配色 Profile、按时间自动切换配色与关闭助手气泡。
*   **本地性能监视面板**：iOS 使用本地模型聊天时可在输入栏上方显示 CPU、Metal 与内存占用，面板支持收起、拖动、触控透传和位置记忆。
*   **气泡功能栏**：聊天气泡下方可挂载自定义功能栏，支持单行横滑、关闭外围边框、iOS 与 watchOS 分别设置默认项目并随用户/助手身份切换，watchOS 可拖拽调整顺序。
*   **字体回退策略**：支持整段/单字粒度的字体回退范围配置，提升中英混排与符号场景的稳定性。
*   **思考与工具时间线**：支持滚动思考预览、自定义/响应式预览高度、流式阶段隐藏完整思考正文、思考耗时、异步思考摘要、工具调用连线时间线、错误重试续跑与多版本回复切换；工具审批改造为行列式选项的原生问答 Sheet。
*   **Markdown 与代码块增强**：支持代码高亮、复制反馈、折叠切换、iOS 代码块预览、Mermaid 渲染、SwiftMath 数学公式、引用块竖线样式、流式尾字淡入与扫光动效。
*   **watchOS 图片阅读**：Markdown 图片和生成图片预览支持数码表冠缩放与拖拽查看，小屏也能认真看图。

#### 工具与自动化

*   **工具中心 + 拓展工具**：统一管理 MCP / Shortcuts / 内建本地工具 / 自定义 JavaScript 工具 / Agent Skills 与内置 `getSystemTime` 等能力，支持按来源和用途分组、聊天工具开关、审批策略、会话级启用、分类收纳与工具详情页。
*   **Agent Skills 技能包**：支持从本地目录、GitHub 仓库链接、GitHub raw / 嵌套目录、默认分支与隐藏目录导入技能包；技能资源支持文本编码读取、大文本分块、文档抽取与图片 OCR。Agent 模式启用本地 Linux 后，Skill 可在逐次授权下执行 `scripts/` 中的脚本；Skill 目录只读挂载，脚本版本与哈希随 Run 冻结，不能借运行中替换文件扩权。
*   **结构化问答工具（ask_user_input）**：支持单题逐步作答、单选/多选互斥规则、自定义输入与返回上题。
*   **自定义 JavaScript 工具**：支持分离式 JS 执行与 AI 生成脚本工具，脚本保存在 `CustomJSTools` 独立目录，创建前会执行脚本验证，可像普通工具一样启用、禁用和配置审批策略。
*   **拓展工具能力补齐**：内置系统时间、SQLite 数据库增删改查、网页卡片展示、输入框填充、沙盒文件操作与反馈工单自动提交工具。
*   **沙盒文件系统工具**：支持搜索、分块读取、差异查看、局部编辑、移动 / 复制 / 删除等文件操作。
*   **MCP 工具调用**：基于官方 Swift [Model Context Protocol](https://modelcontextprotocol.io) SDK，支持远程调用、Streamable HTTP / SSE 传输、重连、超时、握手治理、元数据刷新、资源/模板/提示词读取与能力协商；支持服务器拖拽排序、工具级启用/审批策略、内置服务器删除与恢复，可按聊天暴露开关延迟自动连接。
*   **内建 MCP 服务器**：内置搜索、本地工具和个人数据 MCP 服务器；个人数据服务器可在工具真正调用时按需申请 HealthKit、日历和提醒事项权限。
*   **Siri 快捷指令**：集成 Shortcuts 框架，支持通过快捷指令调用 AI 能力、自定义工具并通过 URL Scheme 路由。
*   **应用内文件管理**：内置可浏览目录的文件管理器，支持直接查看与管理应用沙盒文件，纯文本文件可直接预览。

#### Agent、原生能力与本地 Linux

*   **会话级 Chat / Agent 模式**：模式随会话保存。Chat 不向模型暴露 Agent 工具；Agent 即使未开启 Linux，也可使用 Browser Agent、原生能力和会话协作，开启本地 Linux 后才会增加命令、Linux 文件与本地 stdio MCP。用户终端在两种模式下都能独立使用。
*   **App 内置本地 Linux**：基于 `ish-multiarch` 嵌入最小 Alpine AArch64 RootFS，覆盖 iOS 与 watchOS。系统按实际操作懒安装，不会因为打开开关就启动，也不会静默安装 Python、Node.js 或编译工具；常用环境通过展示命令、软件源和存储影响的一键 recipe 由用户主动执行。
*   **命令、PTY 与任务治理**：提供 `linux_run`、`linux_shell`、`linux_process`、交互式 PTY 终端、任务页、输出分页、取消和诊断。用户终端、Agent 命令与 Agent PTY 相互隔离，但共享授权后的 RootFS 与工作区；标准输出持续在后台收集，不依赖聊天页面保持打开。
*   **工作区、挂载与环境变量**：每个会话拥有独立工作区，可把 App、iCloud Drive 或用户明确授权的外部目录以只读或读写方式挂载进 Linux。环境变量保存在 GRDB 中并在启动进程时注入，面向模型、日志与诊断的副本支持敏感值打码。
*   **统一文件工具与本地 MCP**：现有文件工具同时理解 `app://`、`linux://` 与 `mount://`，不会另造一套绕过审批的 Linux 文件 API。本地 stdio MCP 与 HTTP / SSE 服务器使用同一管理页、排序、工具开关和审批策略，并支持常见 `mcpServers` JSON 导入导出。
*   **Browser Agent**：iOS 受控 WKWebView 支持会话隔离标签页、DOM / 可访问性快照、点击、输入、滚动、JavaScript、截图、下载和用户接管；watchOS 会探测本机真实能力，并可在用户开启后把缺失操作委托给配对 iPhone。
*   **64 个 Apple 原生工具**：按设备、媒体与环境、个人数据、视觉与语言四组提供剪贴板、通知、AlarmKit、地图、设备状态、语音、媒体、WeatherKit、HomeKit、Bluetooth、NFC、联系人、照片、定位、Vision 与 NaturalLanguage 等能力。工具按平台和系统版本报告真实可用性，写入或外部副作用仍需逐次审批；部分 watchOS 缺失能力可委托 iPhone。
*   **持久会话协作**：Agent 可创建隐藏子代理或可见协作会话，选择等待结果、后台交付或完成后续写当前会话。运行状态按 session / run / tool 归属，避免多会话并发时把结果串回错误聊天。
*   **实时活动与后台完成通知**：iOS 会在锁屏和灵动岛显示 Chat / Agent 的运行、等待输入、完成或失败状态，点按可返回对应会话。App 进入后台后会使用系统授予的短时执行窗口继续回复或 Linux 任务；回复确实在后台结束时才发送本地通知，若系统最终挂起任务则准确记录为中断而不是静默重放。

#### 记忆与知识组织

*   **本地 RAG（记忆）**：Embedding 可调用云端 API，也可走已登记的本地嵌入模型，但**向量数据库完全本地运行（SQLite）**；支持文本分块、嵌入进度可视化、记忆编辑、单条记忆重新嵌入、检索时间戳发送控制与主动检索工具。
*   **GRDB 关系化持久化**：核心数据持久化从 JSON 迁移到 GRDB + SQLite，覆盖会话、配置、MCP、世界书、记忆、反馈、快捷指令、用量统计与全局提示词等模块；底层可选启用 SQLCipher 全盘物理加密。
*   **世界书（Worldbook）**：类似 SillyTavern 的 Lorebook 系统，支持角色背景设定管理、条件触发、会话绑定隔离发送、system 注入与 URL 导入；进一步完善了 SillyTavern 多本同时注入、注入预算控制与字段隔离兼容性。
*   **广泛格式兼容**：兼容 PNG naidata、JSON 顶层数组与 `character_book` 等常见世界书格式。
*   **请求日志与测速分析**：内置独立请求日志、Payload 详情页展开、可选的请求明文消息记录、细分 Token 汇总，并提供流式响应速度统计与详情图表。
*   **用量统计**：记录文本请求、模型排行、Token 与缓存 Token，提供 iOS / watchOS 双端统计页、绿色热力图、缓存命中率与跨端同步；今日趋势按小时切分，并提供按模型的 Token 趋势图、占比分析与全部历史范围。
*   **高级渲染**：内置 Markdown 渲染器，支持代码高亮、表格和 LaTeX 数学公式。

#### Daily Pulse 主动情报

*   **每日脉冲（Daily Pulse）**：每天生成一组主动情报卡片，把“你今天可能值得看什么”先整理出来。
*   **Pulse 任务机制**：卡片可以直接转成待跟进任务，这些未完成项会跨天保留，并参与下一次 Pulse 生成。
*   **反馈历史学习**：点赞、降权、隐藏、保存等反馈会沉淀成长期偏好信号，持续影响后续结果。
*   **晨间提醒与继续聊**：支持定时提醒、通知快捷动作、保存为会话和继续聊天，iOS 与 watchOS 两端都能接上这条链路。

#### 安全、同步与运维

*   **应用锁**：基于 Keychain 持久化的 PBKDF2 主密码与生物识别（Face ID / Touch ID）双重保护，支持修改密码时验证旧密码、锁屏自动唤起验证，iOS 与 watchOS 均接入。
*   **数据库全盘加密**：通过 SQLCipher 对核心 SQLite 数据库做物理层加密，支持加密迁移、新密码校验与从加密分库读取，App 内文件浏览与调试工具均兼容。
*   **快照备份与加密**：基于 SQLite Online Backup API 构建脱机数据库快照（含 FTS 剥离），支持完整快照模式、简单密码与 PBKDF2 双模式 AES-256-GCM 加密，并提供二进制 `.elsbackup` 上传与安全恢复流程。
*   **跨端同步**：内置 iOS ↔ watchOS 同步引擎，提供商配置、会话、会话标签、世界书、工具配置、每日脉冲、用量统计、用户画像、全局提示词等数据可自动互通，并支持 WatchConnectivity 快速通道、CloudKit 逐逻辑记录与 Zone change token 增量漫游；设备首次同步且本机与云端状态不一致时（包括任意一端为空）会暂停并由用户裁决，任一覆盖方向都需输入本地化确认短语，覆盖云端则通过权威世代指针切换，避免旧设备重新写回已废弃数据；同时支持会话分叉离线隔离及同消息重试版本合并。
*   **多通道云备份**：支持 ETOS 数据包导出/导入、`.elsbackup` 快照导入、手表端全量导入、CloudKit 传输（含 APNs 静默推送触发后台同步）、iCloud Drive 备份导出/导入、启动备份、损坏自愈，以及通过 S3 兼容对象存储（AWS S3 / Cloudflare R2）签名上传快照、浏览远端快照并从云端下载恢复。
*   **AppConfigStore 配置中心**：全量替代 `@AppStorage`，所有运行时配置走 GRDB 持久化、运行时缓存读取并以后台异步写入派发回主线程，避免主线程 I/O 与多设备配置漂移；支持旧版 UserDefaults 配置的一次性迁移。
*   **更新时间线**：无后端的版本追踪系统，本地从 Build 信息与缓存重建发布时间线，AI 摘要按 Markdown 渲染，iOS 分批展示、watchOS 拆分二级页浏览。
*   **应用内反馈助手**：支持反馈分类、环境信息采集、Git 提交哈希、PoW 提交链路、工单评论对话、引用提交跳转至更新时间线、上传分发通道信息以及双端同步。
*   **网络代理能力**：支持全局/提供商级 HTTP(S)/SOCKS 代理（含鉴权）。
*   **通知与反馈中心增强**：支持工单评论对话、开发者标记展示、状态自动刷新与高优先级本地通知跳转。
*   **局域网调试**：内置局域网调试客户端，并提供 Go 版 TUI 调试工具与内置 Web 控制台；支持 Bonjour 自动发现、文件/SQLite/Provider/模型高级配置/MCP 管理、应用配置编辑与 OpenAI 请求捕获。
*   **文档站**：新增 VitePress 文档站，覆盖安装、首聊、提供商配置、界面导览、模块说明、设计文档和使用建议。
*   **本地化**：支持英语、简体中文、繁体中文（香港）、日语、俄语、法语、西班牙语、阿拉伯语共 8 种语言，并可在 App 内切换语言。

---

## 💸 关于收费与开源

说实话，我最开始是想做免费软件的。
但 Apple Developer Program 每年 $99 的费用，对我一个学生来说确实有点吃力。

后来有位投资人帮我垫付了这笔钱，代价是我需要通过软件收费来偿还这笔投资（而且还要分成给他）。所以 App Store 版本象征性地收了一点费用，这就当是大家众筹帮我还债，顺便买个“不用每七天重签一次”的便利服务。

**但是，开源是我的底线。**

所以现在的规则很简单：
1.  **想省事/支持我**：App Store 见，感谢你的“可乐钱”。
2.  **想折腾/白嫖**：代码就在这儿，GPLv3 协议。如果你有 Mac 和 Xcode，**完全可以自己编译安装，功能上没有任何区别**。
3.  **想体验最新版本**：可以加入 TestFlight 👉 [https://testflight.apple.com/join/d4PgF4CK](https://testflight.apple.com/join/d4PgF4CK)

技术本该共享，我不希望因为几十块钱的门槛，挡住了同样对代码感兴趣的你。

---

## 🛠️ 技术栈

*   **语言**: Swift 6, C / C++（llama.cpp 与 iSH 公共桥接层）
*   **UI**: SwiftUI
*   **架构**: MVVM + Protocol Oriented Programming
*   **数据**: GRDB + SQLite + SQLCipher（核心持久化、本地向量数据库与可选全盘物理加密）, JSON（导入导出与兼容格式）
*   **配置**: AppConfigStore（替代 `@AppStorage`，GRDB 持久化 + 运行时缓存 + 后台异步写入）
*   **安全**: SQLCipher 全盘加密、Keychain PBKDF2 主密码、LocalAuthentication 生物识别、AES-256-GCM 快照加密
*   **网络与传输**: URLSession（API 请求）, Streamable HTTP / SSE（MCP 传输）, WatchConnectivity / CloudKit / APNs 静默推送（跨端与云传输）, WebSocket / HTTP Polling（局域网调试）
*   **AI 协议**: Model Context Protocol（基于官方 [swift-sdk](https://github.com/modelcontextprotocol/swift-sdk)）, OpenAI Chat / Responses, Anthropic Messages, Gemini API, 本地 `local-llama-cpp` 提供商
*   **本地推理**: llama.cpp / GGUF, Swift ↔ C ABI ↔ C++ 桥接, CMake + Ninja 预编译 `libetos-llama.a`, Accelerate / Metal（watchOS 运行期固定 CPU 路径）
*   **本地 Agent Runtime**: `ish-multiarch`、内置 Alpine AArch64 RootFS、Meson + Ninja 预编译 `libiSHApple.a`、PTY、动态挂载、guest 文件 API 与本地 stdio MCP
*   **Agent 能力**: 64 个 Apple 原生 MCP 工具、WKWebView Browser Agent、可执行 Agent Skills、持久会话协作与按 Run 冻结的权限上下文
*   **系统能力**: Siri Shortcuts, WatchConnectivity, CloudKit, UserNotifications, ActivityKit / WidgetKit, iOS 短时后台任务, LocalAuthentication, Speech / AVFoundation
*   **文档站**: VitePress / Teek（仅文档站使用；README 中的代码规模不统计其依赖）
*   **依赖管理**: Swift Package Manager（当前显式依赖 `GRDB.swift`(Eric-Terminal fork)、`SQLCipher.swift`、`swift-sdk`(MCP)、`swift-markdown-ui`、`SwiftMath`、`ZIPFoundation`、`Cepheus`(watchOS 第三方键盘)，并包含其传递依赖 `networkimage`、`swift-cmark`、`eventsource`、`swift-nio` 等）+ llama.cpp / ish-multiarch Git submodule + 独立静态库构建脚本

---

## 🏗️ 项目架构

项目采用双层结构：平台无关的 ETOSCore 框架 + 各平台独立的视图层。Chat、Agent 编排、原生工具、Browser Agent、本地 Linux、MCP 和 Skills 都先进入 ETOSCore 的统一运行上下文、审批、审计与持久化边界，再由 iOS / watchOS 提供各自适合的界面和系统能力实现。

```
ETOSCore/ETOSCore/                         ← 平台无关业务逻辑（481 个 Swift 源文件）
├── AppTool/                            ← 本地工具、自定义 JS 工具、ask_user_input、SQLite 与沙盒文件工具
├── Attachments/                        ← 文件附件文本抽取
├── BrowserAgent/                       ← 受控浏览器会话、DOM 自动化、截图、下载、Cookie 与 iPhone 委托
├── Chat/                               ← 聊天模型、消息版本、导出、渲染状态
│   ├── ConversationRuntime/            ← 持久协作会话、子代理、等待图、预算与续写
│   └── Service/                        ← ChatService 请求编排、响应解析、重试、工具、记忆与世界书注入
├── Config/                             ← AppConfigStore 配置中心、键定义与旧版 UserDefaults 迁移
├── ConfigLoader/                       ← Provider 配置、SQLite 存储、背景与一次性下载状态
├── Core/                               ← 核心模型、JSONValue、请求体控制与共享基础设施
├── DailyPulse/                         ← 每日脉冲生成、筛选、投递、反馈与任务数据
├── Feedback/                           ← 应用内反馈助手、环境采集、DTO 与本地存储
├── Font/                               ← 自定义字体库、字体路由与回退范围
├── LocalDebugServer/                   ← 局域网调试客户端、Web 控制台、文件 / SQLite / Provider 命令与请求捕获
├── LocalAgentRuntime/                  ← 本地 Linux、RootFS、PTY、工作区、挂载、任务、审批与 iSH C ABI
├── LocalLLM/                            ← 本地 GGUF 模型记录、提供商桥接、参数映射与 Swift 推理入口
├── LocalLLMBridge/                      ← llama.cpp C ABI / C++ 桥接层与静态库链接边界
├── Math/                               ← LaTeX/数学公式渲染引擎
├── MCP/                                ← MCP 客户端、内建服务器、服务器存储、Streamable HTTP / SSE 传输（基于官方 swift-sdk）
├── Memory/ + SimilaritySearch/         ← 本地 RAG、嵌入、分块、SQLite 向量检索
├── NativeCapabilities/                 ← 64 个 Apple 原生能力的定义、执行器、权限与双端委托
├── Parsing/                            ← 请求头与参数表达式解析
├── Persistence/                        ← GRDB 主库/辅助库、迁移、启动备份、媒体与文件存储
├── Providers/                          ← Provider 模型、代理配置与 OpenAI / Anthropic / Gemini 适配器
├── Roleplay/                           ← 角色扮演人设、聊天提示词模板与预置角色库
├── Security/                           ← 应用锁状态机、PBKDF2 主密码与数据库加密管理
├── Shortcuts/                          ← Siri Shortcuts、URL Router、导入与执行中继
├── Skills/                             ← Agent Skills 导入、资源读取、脚本快照、授权与本地 Linux 执行
├── Snapshot/                           ← 数据库脱机快照构建、AES-256-GCM 加密与安全恢复
├── Storage/                            ← 沙盒文件浏览、存储统计、缓存清理
├── Sync/                               ← WatchConnectivity 快速通道 / CloudKit / iCloud 漫游 / Manifest / Delta / iCloud Drive / S3 与第三方导入
├── System/                             ← 全局提示词、通知、公告、日志、语音识别、OCR、更新时间线
├── TTS/                                ← 系统 / 云端朗读、队列播放、配置与预设
├── UI/                                 ← 跨端 UI 组件（应用锁界面、跑马灯文本等）
├── UsageAnalytics/                     ← 用量事件、统计仪表盘、按小时趋势与模型 Token 占比
└── Worldbook/                          ← 世界书模型、导入导出、SQLite 存储与触发引擎

ETOS LLM Studio/ETOS LLM Studio iOS App/    ← iOS 视图层（187 个 Swift 源文件）
ETOS LLM Studio/ETOS LLM Studio Watch App/  ← watchOS 视图层（156 个 Swift 源文件）
ETOS LLM Studio/ETOS Agent Widgets/          ← iOS Widget 与 Live Activity
ETOS LLM Studio/ETOS Agent Watch Widgets/    ← watchOS Widget
ETOS LLM Studio/ETOS Workspace Provider/     ← Files / File Provider 系统入口
ETOS LLM Studio/ETOS Agent Share/            ← 分享扩展系统入口
ETOSCore/ETOSCoreTests/                       ← ETOSCore 层测试（147 个 Swift 源文件）
```

云端模型数据流：`View → ChatViewModel → ChatService.shared → Provider Adapter → LLM API`。本地模型数据流：`View → ChatViewModel → ChatService.shared → LocalLLMEngine → LocalLLMBridge → libetos-llama.a / llama.cpp`。Agent 工具数据流：`ChatService → AgentRuntimeContext → 审批与审计 → BrowserAgent / NativeCapabilities / MCP / Skills / LocalAgentRuntime → libiSHApple.a`。会话、Run、工具、记忆、世界书、用量统计与同步数据经由 ETOSCore 层服务和 GRDB/SQLite 统一治理。

---

## 🚀 编译指南

如果你决定自己动手：

1.  **Clone 项目并拉取子模块**:
    ```bash
    git clone --recurse-submodules https://github.com/Eric-Terminal/ETOS-LLM-Studio.git
    cd ETOS-LLM-Studio
    ```
    如果已经 Clone 过但缺少 `Dependencies/llama.cpp` 或 `Dependencies/ish-multiarch`，执行：
    ```bash
    git submodule update --init --recursive
    ```
2.  **环境要求**:
    *   Xcode 26.0+
    *   watchOS 26.0+ SDK
    *   CMake + Ninja（构建 llama.cpp）
    *   Meson + Ninja（构建 iSHApple）
    *   推荐直接执行 `brew install cmake ninja meson`
    *   （如果对不上你可以自己改一改兼容性）
3.  **编译前先生成原生静态库**:
    Xcode 不会在普通 Build Phase 中反复编译 llama.cpp 和 iSH。统一入口会分别调用两套构建脚本，并把两个独立静态库放进同一个 Xcode 搜索目录；它们不会被合并成一份 `.a`。

    如果要编译真机 / Release：
    ```bash
    CONFIGURATION=Release SDK_NAME=iphoneos PLATFORM_NAME=iphoneos ARCHS=arm64 scripts/build-native-static-libraries.sh --parallel
    CONFIGURATION=Release SDK_NAME=watchos PLATFORM_NAME=watchos ARCHS="arm64 arm64_32" scripts/build-native-static-libraries.sh --parallel
    ```
    如果要编译当前 README 使用的 iOS + watchOS Debug 模拟器：
    ```bash
    CONFIGURATION=Debug SDK_NAME=iphonesimulator PLATFORM_NAME=iphonesimulator ARCHS=arm64 scripts/build-native-static-libraries.sh --parallel
    CONFIGURATION=Debug SDK_NAME=watchsimulator PLATFORM_NAME=watchsimulator ARCHS=arm64 scripts/build-native-static-libraries.sh --parallel
    ```

    首次运行会构建 iSHApple 的 iOS / watchOS 设备与模拟器切片，以及当前命令要求的 llama.cpp 平台产物，耗时会明显长于后续构建。缓存命中后，脚本会直接复用现有结果；修改 iSH 不会触发 llama.cpp 重编，反之亦然。`--parallel` 默认按本机 CPU 数传给 CMake，也可使用 `--parallel=8`、`--jobs 8` 或 `-j8` 指定任务数。

    主要产物如下：

    | 产物 | 位置 | 用途 |
    | --- | --- | --- |
    | `iSHApple.xcframework` | `Dependencies/ish-build/iSHApple.xcframework` | iSH 公共多平台产物 |
    | `libiSHApple.a` | `Dependencies/ish-build/products/<platform>/` | 各平台原始 iSH 静态库 |
    | `libetos-llama.a` | `Dependencies/llama-build/products/<platform>-<configuration>/` | llama.cpp / ggml / mtmd |
    | 暂存的 `libiSHApple.a` | 与 `libetos-llama.a` 同目录 | 供当前 Xcode SDK / Configuration 搜索并链接 |

    ETOSCore 通过 `-letos-llama` 链接 llama.cpp；iOS / watchOS 的 Linux 薄桥通过对象链接选项额外链接 `-liSHApple`。因此 Xcode 会同时消费两份静态库，而不是先把它们打包到一起。生成目录均已加入 `.gitignore`，不要提交构建产物。
4.  **打开项目**:
    打开 `ETOS LLM Studio.xcworkspace`（注意是 **workspace** 不是 xcodeproj）。
    首次打开会自动解析并拉取 Swift Package 依赖。
5.  **运行**:
    选择 `ETOS LLM Studio App` Scheme 运行 iOS App；如果要单独调试 watchOS，再选择 `ETOS LLM Studio Watch App` Scheme。连上设备（或模拟器）后，Command + R 即可。
6.  **配置**:
    启动后，去设置里添加你的 API Key。推荐使用"局域网调试"功能，直接把做好的 JSON 配置文件推送到 `Documents/Providers/` 目录下（真的有人会想在 Apple Watch 上面戳 API Key 进去吗）。

### 常见编译问题

*   `ish-multiarch 子模块未初始化`：运行 `git submodule update --init --recursive`。
*   `找不到 meson` / `找不到 ninja` / `cmake: command not found`：运行 `brew install cmake ninja meson`，然后重新执行静态库脚本。
*   `library 'etos-llama' not found` 或 `library 'iSHApple' not found`：确认脚本使用的 `SDK_NAME`、`PLATFORM_NAME` 与 `CONFIGURATION` 和 Xcode 当前目标一致。
*   watchOS 真机归档缺少架构：使用 `ARCHS="arm64 arm64_32"` 重新生成 `watchos` Release 产物。
*   本机环境变量导致 watchOS 链接异常：使用下一节提供的 `env -u ... xcodebuild` 标准命令。

---

## 🧪 自动化测试与构建

如需在命令行执行一键编译或单元测试，请统一使用以下标准 `xcodebuild` 命令（已配置隔离环境变量，避免本机环境污染导致的 watchOS 链接失败）：

* **构建 iOS App（自动包含 watch App）**：
  ```bash
  env -u SDKROOT -u LIBRARY_PATH -u CPATH -u C_INCLUDE_PATH -u CPLUS_INCLUDE_PATH -u OBJC_INCLUDE_PATH xcodebuild -workspace 'ETOS LLM Studio.xcworkspace' -scheme 'ETOS LLM Studio App' -destination 'platform=iOS Simulator,name=iPhone 17 Pro,OS=26.5' build
  ```
* **单独验证 watchOS App 构建**：
  ```bash
  env -u SDKROOT -u LIBRARY_PATH -u CPATH -u C_INCLUDE_PATH -u CPLUS_INCLUDE_PATH -u OBJC_INCLUDE_PATH xcodebuild -workspace 'ETOS LLM Studio.xcworkspace' -scheme 'ETOS LLM Studio Watch App' -destination 'generic/platform=watchOS Simulator' build
  ```
* **运行 ETOSCore 核心框架单元测试**（147 个测试源文件，50,853 行测试代码）：
  ```bash
  env -u SDKROOT -u LIBRARY_PATH -u CPATH -u C_INCLUDE_PATH -u CPLUS_INCLUDE_PATH -u OBJC_INCLUDE_PATH xcodebuild -workspace 'ETOS LLM Studio.xcworkspace' -scheme 'ETOSCore' -destination 'platform=iOS Simulator,name=iPhone 17 Pro,OS=26.5' -parallel-testing-enabled NO test
  ```
* **运行 iOS App 单元与 UI 测试**：
  ```bash
  env -u SDKROOT -u LIBRARY_PATH -u CPATH -u C_INCLUDE_PATH -u CPLUS_INCLUDE_PATH -u OBJC_INCLUDE_PATH xcodebuild -workspace 'ETOS LLM Studio.xcworkspace' -scheme 'ETOS LLM Studio App' -destination 'platform=iOS Simulator,name=iPhone 17 Pro,OS=26.5' -parallel-testing-enabled NO test
  ```
* **运行 watchOS App 单元与 UI 测试**：
  ```bash
  env -u SDKROOT -u LIBRARY_PATH -u CPATH -u C_INCLUDE_PATH -u CPLUS_INCLUDE_PATH -u OBJC_INCLUDE_PATH xcodebuild -workspace 'ETOS LLM Studio.xcworkspace' -scheme 'ETOS LLM Studio Watch App' -destination 'platform=watchOS Simulator,name=Apple Watch Series 11 (46mm),OS=26.5' -parallel-testing-enabled NO test
  ```

---

## 🤝 贡献与 CLA

欢迎提 Issue、PR、文档修订和翻译补全。开始前请阅读 [贡献指南](CONTRIBUTING.md)。

所有贡献都需要签署 [CLA](CLA.md)：首次 PR 请由 PR 作者勾选模板里的声明，或在评论区单独发送：

> I have read the CLA Document and I hereby sign the CLA.

---

## 📬 联系方式

*   **开发者**: Eric Terminal
*   **Email**: ericterminal@ericterminal.com
*   **GitHub**: [Eric-Terminal](https://github.com/Eric-Terminal)

---

本次 README 修订于 2026 年 8 月 12 日。项目更新频率比较高，如果你发现 README 跟不上代码，欢迎直接翻提交记录。
