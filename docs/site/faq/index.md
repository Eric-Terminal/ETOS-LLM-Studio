---
title: 常见问题
description: 装好 App 之后你最有可能问的问题，按主题整理。
---

# 常见问题

按主题排列。如果在这里没找到答案，去对应教程页深入看，或者通过 **设置 → 拓展能力 → 拓展功能 → 反馈助手** 发工单。

## 关于这个 App

### 这是手机 App 还是手表 App？

**两者都是**。ETOS LLM Studio 同时覆盖 iPhone 与 Apple Watch，很多能力会通过同步系统互通。详见 [同步与备份](/modules/sync-backup)。

### 我必须有 Apple Watch 才能用它吗？

**不需要**。Watch 端是特色，但 iPhone 端本身已经是完整客户端。没有 Watch 不影响任何核心功能。

### 这个项目只支持 OpenAI 吗？

**不是**。支持四种 API 格式：

- **OpenAI 兼容**（Chat Completions）—— 覆盖 OpenAI 官方 + 几乎所有第三方中转
- **OpenAI Responses** —— OpenAI 新接口
- **Anthropic** —— Claude 官方
- **Gemini** —— Google 官方

只要服务方支持其中之一，就能接入。详见 [第一次配置提供商](/guide/first-provider)。

### 这个 App 收费吗？

**不收费**。App 本身免费，没有订阅。你只付钱给你接入的 **LLM 服务商**（OpenAI / Anthropic / Google 等）。

### 我的数据会上传到哪里？

**默认不上传任何地方**。所有数据存在本机 SQLite 数据库。除非你**主动**：

- 打开 iCloud 同步（数据加密上传到你自己的 iCloud）
- 启用 Apple Watch 同步（局域网直连，不经过外部）
- 上传备份到你自己的 S3 / R2
- 把会话作为请求发给你接的 LLM 服务（这是模型 API 必须的）

详见 [同步与备份](/modules/sync-backup)。

## 上手与配置

### 第一次最容易卡在哪？

**通常是提供商配置**。建议**先只接一个稳定模型**，把文本聊天跑通，再开图像、语音、工具和代理。详见 [第一次配置提供商](/guide/first-provider)。

### 为什么我感觉很多功能藏得很深？

因为 ETOS 把功能**全收进设置 Tab**，主界面只留聊天。这样做让日常使用变干净，但确实需要看一遍 [界面导览](/guide/interface-tour) 才知道每个入口在哪。

如果一时找不到某功能，记住一个规则：
- **执行类**（聊天、附件） → 聊天页
- **治理类**（提供商、工具、记忆、世界书、同步） → 设置 Tab

### 我设置了模型但聊天页说"选择模型以开始"

回到 **设置 → 当前模型 → 模型**，从列表里**显式选一个**。

如果列表是空的（"暂无可用模型，请先在'提供商与模型管理'中启用。"），说明你的提供商虽然加了但**模型行还没开启用开关**——回到「提供商与模型管理」打开你要用的模型。

### 我配好了但请求总是"鉴权失败"

通常是 API Key 问题：

1. 回控制台**重新复制一次** Key
2. 注意**首尾不要带空格**
3. **不要**在 Key 前手动加 `Bearer `——App 会自动加
4. 检查 Key 是不是过期了

详见 [第一次配置提供商 → 常见错误对照表](/guide/first-provider#%E5%B8%B8%E8%A7%81%E9%94%99%E8%AF%AF%E5%AF%B9%E7%85%A7%E8%A1%A8)。

## 功能选择

### 记忆和世界书应该怎么选？

| 信息会… | 放在 |
| --- | --- |
| 长期反复用、像知识块 | **记忆** |
| 只在特定关键词 / 场景出现时有用 | **世界书** |

简单例子：
- "默认中文回答" → 记忆
- "角色 X 出现时该知道她的背景" → 世界书

详见 [记忆与世界书](/modules/memory-worldbook)。

### Daily Pulse 是什么？

每天定时自动生成的"今天值得看什么"卡片栈。基于你的最近聊天、记忆、反馈历史等本地信号生成。详见 [每日脉冲](/modules/daily-pulse) 和 [每日脉冲设计原理](/design/daily-pulse)。

### 工具和 MCP 是必须用的吗？

**不必**。完全可以把 ETOS 当成纯聊天客户端。但如果你需要更强的工作流能力（让 AI 查文件、调外部服务、运行 Shortcut），工具系统会**非常**值得投入。详见 [工具与 MCP](/modules/tools-and-mcp)。

### 记忆是不是云端托管？

**不是**。Embedding 可以调用云端 API（向量化时用），但**向量数据库本身是本地 SQLite**。

### 我可以在不同会话用不同模型吗？

可以。**聊天页右上角**可以切换当前会话的模型。这只影响当前会话，不改默认。

## 双端 / 同步

### 我一定要在手表上填 API Key 吗？

**不需要**。强烈推荐**在 iPhone 上完成所有配置**，通过同步带到 Watch。详见 [Apple Watch 使用建议](/tips/watch-usage)。

### iCloud 同步会同步 API Key 吗？

**会**。打开 iCloud 同步后，所有数据（含 API Key）都会**加密上传到你自己的 iCloud**。Apple 不会看到，但请确保你的 Apple ID 启用了**双重认证**。

如果你不希望 API Key 上 iCloud，请**只用 Apple Watch 同步**（局域网直连，不上云）。

### 卸载 App 数据会丢吗？

**会**——而且无法找回。卸载前**务必**先做完整快照备份（设置 → 显示与体验 → 同步与备份 → 数据库快照 → 完整快照），存到 iCloud Drive 或 S3。

## 排查与反馈

### 遇到问题怎么排查更有效？

先分清是哪一层出问题：

| 现象 | 大概率是 |
| --- | --- |
| 任何模型都连不上 | 网络 / 代理 |
| 某些模型连不上 | 那个提供商的 Key / Base URL |
| 模型连得上但回答异常 | 系统提示词 / 记忆 / 世界书干扰 |
| 工具调不到 | 审批策略 / 工具中心总开关 / 世界书隔离 |
| 同步不通 | 双端是否同网络 / iCloud 状态 |

定位到层之后再去对应教程页找解决方法。详见 [调试与反馈](/modules/debug-feedback)。

### 怎么给开发者提反馈最有效？

```
设置 → 拓展能力 → 拓展功能 → 反馈助手 → + 新建工单
```

带上：

- **具体复现步骤**（点了哪、填了什么）
- **环境信息**（已自动采集）
- **应用日志**（脱敏后附上，按日期归档好找）
- **截图**（可选）

PoW 完成后提交，状态会自动同步。

### 我的反馈工单一直没回复

ETOS 的开发是开源 / 业余维护节奏，不是 7×24 客服。**通常 24-72 小时**会有第一次响应。如果一周以上没回复，可以在工单里追问或者去 [GitHub Issues](https://github.com/Eric-Terminal/ETOS-LLM-Studio/issues) 复述。

## 其他

### 我能贡献代码 / 提 PR 吗？

可以。仓库地址：[github.com/Eric-Terminal/ETOS-LLM-Studio](https://github.com/Eric-Terminal/ETOS-LLM-Studio)。

提 PR 前请先阅读 [贡献指南](https://github.com/Eric-Terminal/ETOS-LLM-Studio/blob/main/CONTRIBUTING.md)。
所有贡献都需要签署 [CLA](https://github.com/Eric-Terminal/ETOS-LLM-Studio/blob/main/CLA.md)：
首次 PR 中勾选模板里的声明，或在评论区发送
`I have read the CLA Document and I hereby sign the CLA.`。

### 文档站本身怎么贡献？

文档源在 `docs/site/`。本地预览：

```bash
cd docs/site
pnpm install
pnpm docs:dev
```

中文版在根目录，英文版镜像在 `en/`。修改后提 PR 即可。

### 还有问题怎么办

- 看 [入门总览](/guide/getting-started)——可能你在某个步骤跳过了什么
- 看 [界面导览](/guide/interface-tour)——可能那个功能你只是没找到入口
- 看 [隐藏技巧](/tips/hidden-gems)——可能是个手势没被提到
- 提反馈工单 / GitHub Issue
