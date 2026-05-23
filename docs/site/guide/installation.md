---
title: 安装与首次启动
description: 把 ETOS LLM Studio 装到 iPhone 和 Apple Watch 上，并完成第一次启动后的必要检查。
---

# 安装与首次启动

ETOS LLM Studio 是一款运行在 iPhone 和 Apple Watch 上的**原生** AI 客户端。它不是浏览器套壳，也不是聊天机器人前端：聊天、记忆、世界书、每日脉冲、MCP 工具、同步备份这些功能都在两端 App 本地运行，模型请求直接从你的手机/手表发出，**不经过任何中间服务器**。

这一页帮你把 App 装到设备上，并在第一次启动之后做完最低限度的检查，让后续教程能顺利进行。

## 新手必读

### 你需要准备什么

| 项目 | 要求 | 是否必需 |
| --- | --- | --- |
| iPhone | iOS 17 或更高 | ✅ 必需 |
| Apple Watch | watchOS 10 或更高 | ⚪ 可选——只想用手机也完全可以 |
| Apple ID | 任意区域 | ✅ 必需 |
| LLM 服务的 API Key | 至少一个 | ✅ 必需 |
| 网络 | 能稳定访问你选用的模型服务地址 | ✅ 必需 |

::: tip API Key 是什么？
API Key 是 LLM 服务商（OpenAI、Anthropic、Google 等）发给你的一串字符，长得像 `sk-xxxxxxxxxxxxxxxx`。它代表「这个请求来自我这个付费/试用用户」，模型才会愿意回答。**不同厂商的 Key 互不通用**——OpenAI 的 Key 不能拿去调 Anthropic。

如果你现在还没有任何 Key，先去 [OpenAI Platform](https://platform.openai.com/api-keys)、[Anthropic Console](https://console.anthropic.com/) 或 [Google AI Studio](https://aistudio.google.com/apikey) 之一申请一个，再回来继续。
:::

### 装 App

ETOS LLM Studio 目前**未上架 App Store**，通过两种方式安装：

**方式 A：TestFlight（推荐普通用户）**

1. 在 iPhone 上装上 [TestFlight](https://apps.apple.com/app/testflight/id899247664)。
2. 打开项目 [GitHub Releases](https://github.com/Eric-Terminal/ETOS-LLM-Studio/releases) 页面里附带的 TestFlight 邀请链接。
3. 按 TestFlight 弹出的"接受"和"安装"提示完成即可。
4. 安装完成会在主屏幕上看到 **ETOS LLM Studio** 图标。

**方式 B：Xcode 自行编译（适合开发者）**

如果你装了 Xcode 16 或更高版本，可以 clone 仓库，用 `ETOS LLM Studio.xcworkspace`（注意是 **workspace**，不是 `xcodeproj`）打开，选择 `ETOS LLM Studio App` 这个 Scheme，连上配好签名的真机后点 Run。Apple Watch App 会作为 iOS App 的嵌入目标一起编译进去。

::: warning 不要直接打开 xcodeproj
项目同时存在 `.xcodeproj` 和 `.xcworkspace`，请始终打开 **workspace**。`xcodeproj` 缺少 Swift Package 依赖配置，编译会失败。
:::

### Apple Watch 同步安装

iPhone App 装好之后，Watch App 通常会自动推送到配对的 Apple Watch 上。**如果没看到**：

1. 在 iPhone 打开系统自带的"Watch" App（图标是表盘）。
2. 滚到最下方的"可用 App"区域。
3. 找到"ETOS LLM Studio"，点旁边的"安装"。

装好后，在 Apple Watch 上按数字表冠回到表盘，滑出 App 网格/列表，看到 ETOS LLM Studio 图标即为安装成功。

### 第一次启动 iPhone App，你会看到什么

第一次启动**没有引导动画**——这是个工具型 App，不是社交产品。你会直接看到主界面，底部 Tab Bar 只有两个标签：

- **聊天**（默认 Tab）：上半部分是当前会话窗口，下方是输入区。第一次进来会有一个空的「新对话」等你发消息。
- **设置**：所有配置都收在这里——提供商、模型、工具、记忆、世界书、同步、外观、每日脉冲……

::: info 为什么主界面这么少
ETOS LLM Studio 把功能全收进"设置"，主界面只留聊天。代价是设置页比较长，好处是你日常使用时不会被运营位、广告、推荐位打扰。

每个设置入口分别打开会看到什么，详见 [界面导览](/guide/interface-tour)。
:::

### 启动之后必做的三件事

**在做任何其他事情之前**，请按顺序完成下面三步：

#### 1. 处理权限弹窗

iOS 第一次启动会弹出几个权限请求，按以下原则处理：

| 权限 | 用来做什么 | 推荐选择 |
| --- | --- | --- |
| 本地网络 | 局域网调试 / iPhone 与 Watch 互相发现 | 允许 |
| 通知 | 每日脉冲推送、生成完成提醒 | 允许 |
| 麦克风 | 语音输入、录音附件 | 允许（不用时也可以以后再关） |

漏选了不用慌：iOS 系统设置 → ETOS LLM Studio 里可以随时改。

#### 2. 配置至少一个提供商

没有提供商，App **完全没法聊天**。这是最关键的一步，单独写在 [第一次配置提供商](/guide/first-provider)。

#### 3. 配好之后回到"设置"看顶部"当前模型"

回到"设置"页，最顶部「当前模型」分组里应该已经显示了你刚启用的模型名字。

如果这里显示**"暂无可用模型，请先在'提供商与模型管理'中启用。"**，说明你虽然加了提供商，但还没在提供商下面勾选具体哪个模型用于聊天。回到「设置 → 提供商与模型管理」打开你想用的那个模型即可。

## 进阶选项

### 我只有 Apple Watch，没有 iPhone

可以联网调模型，但**不推荐**。Watch App 能独立发请求，但所有配置（提供商、世界书、记忆等）的录入界面都在 iPhone 上——Watch 屏幕太小，硬塞表单并不现实。

如果你确实只有 Watch，目前的方案是借朋友的 iPhone 配好，从「设置 → 同步与备份」导出 ETOS 数据包，再用 iCloud Drive 把数据包传到自己的 Watch。流程详见 [同步与备份](/modules/sync-backup)。

### 数据存哪里 / 怎么备份

ETOS LLM Studio 不依赖任何云账号，所有数据默认**只存本机**：

- **iPhone**：App 沙盒内的 SQLite 数据库。可在 iOS 系统设置 → 通用 → iPhone 储存空间 → ETOS LLM Studio 里看到占用大小。
- **Apple Watch**：同步过来的镜像版本，体积较小。
- **跨设备**：通过 iCloud Drive 中转的 ETOS 数据包，或局域网直连同步。

::: danger 卸载会丢数据
卸载 iPhone App 会**永久删除本机数据库**，且 iCloud 上不会留备份。卸载之前一定要先从「设置 → 同步与备份 → 导出 ETOS 数据包」做一份完整备份，并把数据包存到你信得过的位置（iCloud Drive、外接硬盘均可）。
:::

### 从其他 App 迁移过来

如果你之前用过 Cherry Studio、RikkaHub、Kelivo 或 ChatGPT 官方导出，可以直接把它们的导出文件喂给 ETOS：

**设置 → 同步与备份 → 第三方导入 → 选择格式 → 选择文件**

支持的格式包括：

- **Cherry Studio**：完整 backup.zip
- **RikkaHub**：导出的 JSON
- **Kelivo**：导出的 JSON
- **ChatGPT 官方导出**：`conversations.json`

会话、提供商配置、模型列表会尽量映射到 ETOS 的结构里；无法识别的字段会被静默忽略，不会污染你的数据库。

### 编译失败常见错误

- **报 watchOS link error**：终端里残留了 `SDKROOT` 等环境变量。改用 `env -u SDKROOT -u LIBRARY_PATH -u CPATH -u C_INCLUDE_PATH -u CPLUS_INCLUDE_PATH -u OBJC_INCLUDE_PATH xcodebuild ...` 前缀执行编译命令即可。
- **`Could not get trait set for device Watch7,18`**：Xcode 资源裁剪阶段的已知工具链警告，**不影响代码编译**。改用 `generic/platform=watchOS Simulator` 作为目标可避开。
- **签名失败**：检查 Apple ID 是否已加入 Xcode → Settings → Accounts，并把 Bundle Identifier 改成你自己的反向域名。

## 下一步

装好 App 了 → [第一次配置提供商](/guide/first-provider)
